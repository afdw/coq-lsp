(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(************************************************************************)
(* Coq Language Server Protocol                                         *)
(* Copyright 2019 MINES ParisTech -- Dual License LGPL 2.1 / GPL3+      *)
(* Copyright 2019-2023 Inria      -- Dual License LGPL 2.1 / GPL3+      *)
(* Written by: Emilio J. Gallego Arias                                  *)
(************************************************************************)

(* Handler for document *)
module Handle = struct
  type t =
    { doc : Doc.t
    ; cp_requests : Int.Set.t
          (* For now we just store the request id to wake up on completion,
             later on we may want to store a more interesting type, for example
             "wake up when a location is reached", or always to continue the
             streaming *)
    ; pt_requests : (int * (int * int)) list (* id, point *)
    }

  let pt_eq (id1, (l1, c1)) (id2, (l2, c2)) = id1 = id2 && l1 = l2 && c1 = c2

  let pt_gt x y =
    let lx, cx = x in
    let ly, cy = y in
    lx > ly || (lx = ly && cx > cy)

  let doc_table : (Lang.LUri.File.t, t) Hashtbl.t = Hashtbl.create 39

  let create ~uri ~doc =
    (match Hashtbl.find_opt doc_table uri with
    | None -> ()
    | Some _ ->
      Io.Log.trace "do_open"
        ("file "
        ^ Lang.LUri.File.to_string_uri uri
        ^ " not properly closed by client"));
    Hashtbl.add doc_table uri
      { doc; cp_requests = Int.Set.empty; pt_requests = [] }

  let close ~uri = Hashtbl.remove doc_table uri
  let find_opt ~uri = Hashtbl.find_opt doc_table uri

  let _update_doc ~handle ~(doc : Doc.t) =
    Hashtbl.replace doc_table doc.uri { handle with doc }

  let pt_ids l = List.map (fun (id, _) -> id) l |> Int.Set.of_list

  (* Clear requests *)
  let clear_requests ~uri =
    match Hashtbl.find_opt doc_table uri with
    | None -> Int.Set.empty
    | Some { cp_requests; pt_requests; doc } ->
      let invalid_reqs = Int.Set.union cp_requests (pt_ids pt_requests) in
      Hashtbl.replace doc_table uri
        { doc; cp_requests = Int.Set.empty; pt_requests = [] };
      invalid_reqs

  (* Clear requests and update doc *)
  let update_doc_version ~(doc : Doc.t) =
    let invalid_reqs = clear_requests ~uri:doc.uri in
    Hashtbl.replace doc_table doc.uri
      { doc; cp_requests = Int.Set.empty; pt_requests = [] };
    invalid_reqs

  let map_cp_requests ~uri ~f =
    match Hashtbl.find_opt doc_table uri with
    | Some { doc; cp_requests; pt_requests } ->
      let cp_requests = f cp_requests in
      Hashtbl.replace doc_table uri { doc; cp_requests; pt_requests }
    | None -> ()

  let attach_cp_request ~uri ~id =
    let f cp_requests = Int.Set.add id cp_requests in
    map_cp_requests ~uri ~f

  let remove_cp_request ~uri ~id =
    let f cp_requests = Int.Set.remove id cp_requests in
    map_cp_requests ~uri ~f

  let map_pt_requests ~uri ~f =
    match Hashtbl.find_opt doc_table uri with
    | Some { doc; cp_requests; pt_requests } ->
      let pt_requests = f pt_requests in
      Hashtbl.replace doc_table uri { doc; cp_requests; pt_requests }
    | None -> ()

  (* This needs to be insertion sort! *)
  let pt_insert x xs = CList.insert pt_gt x xs

  let attach_pt_request ~uri ~id ~point =
    let f pt_requests = pt_insert (id, point) pt_requests in
    map_pt_requests ~uri ~f

  let remove_pt_request ~uri ~id ~point =
    let f pt_requests = CList.remove pt_eq (id, point) pt_requests in
    map_pt_requests ~uri ~f

  (* For now only on completion, I think we want check to return the list of
     requests that can be served / woken up *)
  let do_requests ~doc ~handle =
    let handle = { handle with doc } in
    match doc.completed with
    | Yes _ ->
      let pt_ids = pt_ids handle.pt_requests in
      let wake_up = Int.Set.union pt_ids handle.cp_requests in
      let pt_requests = [] in
      let cp_requests = Int.Set.empty in
      ({ handle with cp_requests; pt_requests }, wake_up)
    | Stopped range ->
      let fullfilled, delayed =
        List.partition
          (fun (_id, point) -> Doc.Target.reached ~range point)
          handle.pt_requests
      in
      let handle = { handle with pt_requests = delayed } in
      (handle, pt_ids fullfilled)
    | Failed _ | FailedPermanent _ -> (handle, Int.Set.empty)

  (* trigger pending incremental requests *)
  let update_doc_info ~handle ~(doc : Doc.t) =
    let handle, requests = do_requests ~doc ~handle in
    Hashtbl.replace doc_table doc.uri handle;
    requests
end

let diags_of_doc doc = List.concat_map Doc.Node.diags doc.Doc.nodes

(* This is temporary for 0.1.7 and our ER project, we need to reify this to a
   general structure *)
module Register : sig
  module Completed : sig
    type t = io:Io.CallBack.t -> token:Coq.Limits.Token.t -> doc:Doc.t -> unit
  end

  val add : Completed.t -> unit
  val fire : io:Io.CallBack.t -> token:Coq.Limits.Token.t -> doc:Doc.t -> unit
end = struct
  module Completed = struct
    type t = io:Io.CallBack.t -> token:Coq.Limits.Token.t -> doc:Doc.t -> unit
  end

  let callback : Completed.t list ref = ref []
  let add fn = callback := fn :: !callback
  let fire ~io ~token ~doc = List.iter (fun f -> f ~io ~token ~doc) !callback
end

let send_diags ~io ~token:_ ~doc =
  let diags = diags_of_doc doc in
  if List.length diags > 0 || !Config.v.send_diags then
    let uri, version = (doc.uri, doc.version) in
    Io.Report.diagnostics ~io ~uri ~version diags

let send_perf_data ~io ~token:_ ~(doc : Doc.t) =
  (* The if below needs to be moved to registrationt time, but for now we keep
     it for now until the plugin workflow is clearer *)
  if !Config.v.send_perf_data then
    let uri, version = (doc.uri, doc.version) in
    Io.Report.perfData ~io ~uri ~version (Perf_analysis.make doc)

let () = Register.add send_perf_data
let () = Register.add send_diags

module Check : sig
  val schedule : uri:Lang.LUri.File.t -> unit
  val deschedule : uri:Lang.LUri.File.t -> unit

  val maybe_check :
    io:Io.CallBack.t -> token:Coq.Limits.Token.t -> (Int.Set.t * Doc.t) option
end = struct
  let pending = ref []

  let pend_pop = function
    | [] -> []
    | _ :: p -> p

  (** Push to front; beware of complexity here? Usually we don't have more than
      10-20 files open in this use case; other use cases may require a more
      efficient data-structure. *)
  let pend_push uri pend = uri :: CList.remove Lang.LUri.File.equal uri pend

  (** Try until [Some] *)
  let rec pend_try f = function
    | [] -> None
    | l :: tt -> (
      match f l with
      | None -> pend_try f tt
      | Some r -> Some r)

  let get_check_target pt_requests =
    let target_of_pt_handle (_, (l, c)) = Doc.Target.Position (l, c) in
    Option.map target_of_pt_handle (List.nth_opt pt_requests 0)

  (* Notification handling; reply is optional / asynchronous *)
  let check ~io ~token ~uri =
    Io.Log.trace "process_queue" "resuming document checking";
    match Handle.find_opt ~uri with
    | Some handle -> (
      let target = get_check_target handle.pt_requests in
      match target with
      (* If we are in lazy mode and we don't have any full document requests
         pending, we just deschedule *)
      | None
        when !Config.v.check_only_on_request
             && Int.Set.is_empty handle.cp_requests ->
        pending := pend_pop !pending;
        None
      | (None | Some _) as tgt ->
        let target = Option.default Doc.Target.End tgt in
        let doc = Doc.check ~io ~token ~target ~doc:handle.doc () in
        let requests = Handle.update_doc_info ~handle ~doc in
        if Doc.Completion.is_completed doc.completed then
          Register.fire ~io ~token ~doc;
        (* Remove from the queue *)
        if Doc.Completion.is_completed doc.completed then
          pending := pend_pop !pending;
        Some (requests, doc))
    | None ->
      pending := pend_pop !pending;
      Io.Log.trace "Check.check"
        ("file " ^ Lang.LUri.File.to_string_uri uri ^ " not available");
      None

  let maybe_check ~io ~token =
    pend_try (fun uri -> check ~io ~token ~uri) !pending

  let schedule ~uri = pending := pend_push uri !pending

  let deschedule ~uri =
    pending := CList.remove Lang.LUri.File.equal uri !pending
end

let create ~token ~env ~uri ~raw ~version =
  let doc = Doc.create ~token ~env ~uri ~raw ~version in
  Handle.create ~uri ~doc;
  Check.schedule ~uri

(* Set this to false for < 8.17, we could parse the version but not worth it. *)
let sane_coq_base_version = true

let sane_coq_branch =
  CString.string_contains ~where:Coq_config.version ~what:"+lsp"

(* for testing in master, set this to true *)
let force_single_mode = false

let sane_coq_version =
  (sane_coq_base_version || sane_coq_branch) && not force_single_mode

(* Can't wait for the day this goes away *)
let tainted = ref false

let create ~io ~token ~env ~uri ~raw ~version =
  if !tainted && not sane_coq_version then (
    (* Error due to Coq bug *)
    let message =
      "You have opened two or more Coq files simultaneously in the server\n\
       Unfortunately Coq's < 8.17 doesn't properly support that setup yet\n\
       You'll need to close all files but one, and restart the server.\n\n\
       Check coq-lsp webpage (Working with multiple files section) for\n\
       instructions on how to install a fixed branch for earlier Coq versions."
    in
    let lvl = Io.Level.error in
    Io.Report.message ~io ~lvl ~message;
    let doc = Doc.create_failed_permanent ~env ~uri ~raw ~version in
    Handle.create ~uri ~doc;
    Check.schedule ~uri)
  else (
    tainted := true;
    create ~token ~env ~uri ~raw ~version)

let change ~io:_ ~token ~(doc : Doc.t) ~version ~raw =
  let uri = doc.uri in
  Io.Log.trace "bump file"
    (Lang.LUri.File.to_string_uri uri ^ " / version: " ^ string_of_int version);
  let tb = Unix.gettimeofday () in
  (* The discrepancy here will be solved once we remove the [Protect.*.t] types
     from `doc.mli` *)
  let doc = Doc.bump_version ~token ~version ~raw doc in
  let diff = Unix.gettimeofday () -. tb in
  Io.Log.trace "bump file took" (Format.asprintf "%f" diff);
  (* Just in case for the future, we update the document before requesting it to
     be checked *)
  let invalid = Handle.update_doc_version ~doc in
  Check.schedule ~uri;
  invalid

let change ~io ~token ~uri ~version ~raw =
  match Handle.find_opt ~uri with
  | None ->
    Io.Log.trace "DocHandle.find"
      ("file " ^ Lang.LUri.File.to_string_uri uri ^ " not available");
    Int.Set.empty
  | Some { doc; _ } ->
    if version > doc.version then change ~io ~token ~doc ~version ~raw
    else
      (* That's a weird case, get got changes without a version bump? Do nothing
         for now *)
      Int.Set.empty

let close ~uri =
  (* XXX: Our handling of the "queue" is not good, handle should take care of
     that as to avoid desync between the queue and the handle table. *)
  Check.deschedule ~uri;
  Handle.close ~uri

module Request = struct
  type request =
    | FullDoc
    | PosInDoc of
        { point : int * int
        ; version : int option
        }

  type t =
    { id : int
    ; uri : Lang.LUri.File.t
    ; postpone : bool
    ; request : request
    }

  type action =
    | Now of Doc.t
    | Postpone
    | Cancel

  let with_doc ~f ~uri =
    match Handle.find_opt ~uri with
    | None ->
      Io.Log.trace "Request.add"
        ("document " ^ Lang.LUri.File.to_string_uri uri ^ " not available");
      (* XXX Should be cancelled *)
      Cancel
    | Some { doc; _ } -> f doc

  let request_in_range ~(doc : Doc.t) ~version (line, col) =
    let in_range =
      match doc.completed with
      | Yes _ -> true
      | Failed range | FailedPermanent range | Stopped range ->
        Doc.Target.reached ~range (line, col)
    in
    let in_range =
      match version with
      | None -> in_range
      | Some version -> doc.version >= version && in_range
    in
    in_range

  (** Add a request to be served; returns [true] if request is added to the
      queue , [false] if the request can be already answered. *)
  let add { id; uri; postpone; request } =
    match request with
    | FullDoc ->
      with_doc ~uri ~f:(fun doc ->
          match (Doc.Completion.is_completed doc.completed, postpone) with
          | true, _ -> Now doc
          | false, false -> Cancel
          | false, true ->
            Handle.attach_cp_request ~uri ~id;
            Check.schedule ~uri;
            Postpone)
    | PosInDoc { point; version } ->
      with_doc ~uri ~f:(fun doc ->
          let in_range = request_in_range ~doc ~version point in
          match (in_range, postpone) with
          | true, _ -> Now doc
          | false, true ->
            Handle.attach_pt_request ~uri ~id ~point;
            Check.schedule ~uri;
            Postpone
          | false, false -> Cancel)

  (** Removes the request from the list of things to wake up *)
  let remove { id; uri; postpone = _; request } =
    match request with
    | FullDoc -> Handle.remove_cp_request ~uri ~id
    | PosInDoc { point; _ } -> Handle.remove_pt_request ~uri ~id ~point
end
