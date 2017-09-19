(*
 * Copyright (C) 2015 Citrix Inc
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Lwt.Infix
(* Xapi external interfaces: *)
module Xen_api = Xen_api_lwt_unix

(* Xapi internal interfaces: *)
module SM = Storage_interface.ClientM(struct
    type 'a t = 'a Lwt.t
    let fail, return, bind = Lwt.(fail, return, bind)

    let (>>*=) m f = m >>= function
      | `Ok x -> f x
      | `Error e ->
        let b = Buffer.create 16 in
        let fmt = Format.formatter_of_buffer b in
        Protocol_lwt.Client.pp_error fmt e;
        Format.pp_print_flush fmt ();
        Lwt.fail_with (Buffer.contents b)

    (* A global connection for the lifetime of this process *)
    let switch =
      Protocol_lwt.Client.connect ~switch:!Xcp_client.switch_path ()
      >>*= fun switch ->
      Lwt.return switch

    let rpc call =
      switch >>= fun switch ->
      Protocol_lwt.Client.rpc ~t:switch ~queue:!Storage_interface.queue_name ~body:(Jsonrpc.string_of_call call) ()
      >>*= fun result ->
      Lwt.return (Jsonrpc.response_of_string result)
  end)

(* TODO share these "require" functions with the nbd package. *)
let require name arg = match arg with
  | None -> failwith (Printf.sprintf "Please supply a %s argument" name)
  | Some x -> x

let require_str name arg =
  require name (if arg = "" then None else Some arg)

let capture_exception f x =
  Lwt.catch
    (fun () -> f x >>= fun r -> Lwt.return (`Ok r))
    (fun e -> Lwt.return (`Error e))

let release_exception = function
  | `Ok x -> Lwt.return x
  | `Error e -> Lwt.fail e

let with_block filename f =
  Block.connect filename
  >>= function
  | `Error _ -> Lwt.fail_with (Printf.sprintf "Unable to read %s" filename)
  | `Ok x ->
    capture_exception f x
    >>= fun r ->
    Block.disconnect x
    >>= fun () ->
    release_exception r

let with_attached_vdi sr vdi read_write f =
  let pid = Unix.getpid () in
  let connection_uuid = Uuidm.v `V4 |> Uuidm.to_string in
  let datapath_id = Printf.sprintf "xapi-nbd/%s/%s/%d" vdi connection_uuid pid in
  let dbg = Printf.sprintf "xapi-nbd:with_attached_vdi/%s" datapath_id in
  SM.DP.create ~dbg ~id:datapath_id
  >>= fun dp ->
  SM.VDI.attach ~dbg ~dp ~sr ~vdi ~read_write
  >>= fun attach_info ->
  SM.VDI.activate ~dbg ~dp ~sr ~vdi
  >>= fun () ->
  capture_exception f attach_info.Storage_interface.params
  >>= fun r ->
  SM.DP.destroy ~dbg ~dp ~allow_leak:true
  >>= fun () ->
  release_exception r


let ignore_exn t () = Lwt.catch t (fun _ -> Lwt.return_unit)

let handle_connection xen_api_uri fd tls_role =

  let with_session rpc uri f =
    ( match Uri.get_query_param uri "session_id" with
      | Some session_id ->
        (* Validate the session *)
        Xen_api.Session.get_uuid ~rpc ~session_id ~self:session_id
        >>= fun _ ->
        Lwt.return session_id
      | None ->
        Lwt.fail_with "No session_id parameter provided"
    ) >>= fun session_id ->
    f uri rpc session_id
  in


  let serve t uri rpc session_id =
    let path = Uri.path uri in (* note preceeding / *)
    let vdi_uuid = if path <> "" then String.sub path 1 (String.length path - 1) else path in
    Xen_api.VDI.get_by_uuid ~rpc ~session_id ~uuid:vdi_uuid
    >>= fun vdi_ref ->
    Xen_api.VDI.get_record ~rpc ~session_id ~self:vdi_ref
    >>= fun vdi_rec ->
    Xen_api.SR.get_uuid ~rpc ~session_id ~self:vdi_rec.API.vDI_SR
    >>= fun sr_uuid ->
    with_attached_vdi sr_uuid vdi_rec.API.vDI_location (not vdi_rec.API.vDI_read_only)
      (fun filename ->
         with_block filename (Nbd_lwt_unix.Server.serve t (module Block))
      )
  in

  Nbd_lwt_unix.with_channel fd tls_role
    (fun channel ->
       Nbd_lwt_unix.Server.with_connection channel
         (fun export_name svr ->
           let rpc = Xen_api.make xen_api_uri in
           let uri = Uri.of_string export_name in
           with_session rpc uri (serve svr)
         )
    )

let wait_for_file_to_appear path timeout () =
  let wait () =
    Lwt_inotify.create () >>= fun inotify ->
    Lwt.finalize
      (fun () ->
         let dir = Filename.dirname path in
         let filename = Filename.basename path in
         Lwt_inotify.add_watch inotify dir [Inotify.S_Create] >>= fun watch ->
         Lwt.finalize
           (fun () ->
              (* Check file existence after adding watch to avoid a race *)
              Lwt_unix.file_exists path >>= fun exists ->
              if exists then
                Lwt.return_unit
              else begin
                Lwt_log.notice_f "File '%s' does not exist, waiting for it to be created using inotify" path >>= fun () ->
                let rec loop () =
                  Lwt_inotify.read inotify >>= fun event ->
                  Lwt_log.notice_f "Received inotify event: %s" (Inotify.string_of_event event) >>= fun () ->
                  let (_watch, kinds, cookie, event_filename) = event in
                  match event_filename with
                  | Some event_filename when event_filename = filename ->
                    if List.exists ((=) Inotify.Create) kinds then
                      (* The file we've been waiting for has been created *)
                      Lwt.return_unit
                    else loop ()
                  | _ -> loop ()
                in loop ()
              end)
           (fun () -> Lwt_inotify.rm_watch inotify watch)
      )
      (fun () -> Lwt_inotify.close inotify)
  in

  let timeout =
    let timeout = 5.0 in
    Lwt_unix.sleep timeout >>= fun () ->
    let msg = Printf.sprintf "File '%s' did not appear in %f seconds" path timeout in
    Lwt_log.fatal msg >>= fun () ->
    Lwt.fail_with msg
  in

  Lwt.pick [wait (); timeout]

(* TODO use the version from nbd repository *)
let init_tls_get_server_ctx ~certfile ~ciphersuites no_tls =

  if no_tls then Lwt.return_none
  else (
    wait_for_file_to_appear certfile 5.0 () >>= fun () ->
    let certfile = require_str "certfile" certfile in
    let ciphersuites = require_str "ciphersuites" ciphersuites in
    Lwt.return_some (Nbd_lwt_unix.TlsServer
      (Nbd_lwt_unix.init_tls_get_ctx ~certfile ~ciphersuites)
    )
  )

let main port xen_api_uri certfile ciphersuites no_tls =
  let t () =
    Lwt_log.notice_f "Starting xapi-nbd: port = '%d'; xen_api_uri = '%s'; certfile = '%s'; ciphersuites = '%s' no_tls = '%b'" port xen_api_uri certfile ciphersuites no_tls >>= fun () ->
    Lwt_log.notice "Initialising TLS" >>= fun () ->
    init_tls_get_server_ctx ~certfile ~ciphersuites no_tls >>= fun tls_role ->
    let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt.finalize
      (fun () ->
         Lwt_log.notice "Setting up server socket" >>= fun () ->
         Lwt_unix.setsockopt sock Lwt_unix.SO_REUSEADDR true;
         let sockaddr = Lwt_unix.ADDR_INET(Unix.inet_addr_any, port) in
         Lwt_unix.bind sock sockaddr;
         Lwt_unix.listen sock 5;
         Lwt_log.notice "Listening for incoming connections" >>= fun () ->
         let rec loop () =
           Lwt_unix.accept sock
           >>= fun (fd, _) ->
           Lwt_log.notice "Got new client" >>= fun () ->
           (* Background thread per connection *)
           let _ =
             Lwt.catch
               (fun () ->
                  Lwt.finalize
                    (fun () -> handle_connection xen_api_uri fd tls_role)
                    (* ignore the exception resulting from double-closing the socket *)
                    (ignore_exn (fun () -> Lwt_unix.close fd))
               )
               (fun e -> Lwt_log.error_f "Caught exception while handling client: %s" (Printexc.to_string e))
           in
           loop ()
         in
         loop ()
      )
      (ignore_exn (fun () -> Lwt_unix.close sock))
  in
  (* Log unexpected exceptions *)
  Lwt_main.run
    (Lwt.catch t
       (fun e ->
          Lwt_log.fatal_f "Caught unexpected exception: %s" (Printexc.to_string e) >>= fun () ->
          Lwt.fail e
       )
    );

  `Ok ()

open Cmdliner

(* Help sections common to all commands *)

let _common_options = "COMMON OPTIONS"
let help = [
  `S _common_options;
  `P "These options are common to all commands.";
  `S "MORE HELP";
  `P "Use `$(mname) $(i,COMMAND) --help' for help on a single command."; `Noblank;
  `S "BUGS"; `P (Printf.sprintf "Check bug reports at %s" Consts.project_url);
]

let certfile =
  let doc = "Path to file containing TLS certificate." in
  Arg.(value & opt string "" & info ["certfile"] ~doc)
let ciphersuites =
  let doc = "Set of ciphersuites for TLS (specified in the format accepted by OpenSSL, stunnel etc.)" in
  Arg.(value & opt string "!EXPORT:RSA+AES128-SHA256" & info ["ciphersuites"] ~doc)
let no_tls =
  let doc = "Use NOTLS mode (refusing TLS) instead of the default FORCEDTLS." in
  Arg.(value & flag & info ["no-tls"] ~doc)

let cmd =
  let doc = "Expose VDIs over authenticated NBD connections" in
  let man = [
    `S "DESCRIPTION";
    `P "Expose all accessible VDIs over NBD. Every VDI is addressible through a URI, where the URI will be authenticated by xapi.";
  ] @ help in
  (* TODO for port, certfile, ciphersuites and no_tls: use definitions from nbd repository. *)
  (* But consider making ciphersuites mandatory here in a local definition. *)
  let port =
    let doc = "Local port to listen for connections on" in
    Arg.(value & opt int Consts.standard_nbd_port & info [ "port" ] ~doc) in
  let xen_api_uri =
    let doc = "The URI to use when making XenAPI calls. It must point to the pool master, or to xapi's local Unix domain socket, which is the default." in
    Arg.(value & opt string Consts.xapi_unix_domain_socket_uri & info [ "xen-api-uri" ] ~doc) in
  Term.(ret (pure main $ port $ xen_api_uri $ certfile $ ciphersuites $ no_tls)),
  Term.info "xapi-nbd" ~version:"1.0.0" ~doc ~man ~sdocs:_common_options

let setup_logging () =
  Lwt_log.default := Lwt_log.syslog ~facility:`Daemon ();
  (* Display all log messages of level "notice" and higher (this is the default Lwt_log behaviour) *)
  Lwt_log.add_rule "*" Lwt_log.Notice

let () =
  setup_logging ();
  match Term.eval cmd with
  | `Error _ -> exit 1
  | _ -> exit 0
