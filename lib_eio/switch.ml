type t = {
  id : Ctf.id;
  mutable fibres : int;
  mutable extra_exceptions : exn list;
  on_release : (unit -> unit) Lwt_dllist.t;
  waiter : unit Waiters.t;              (* The main [top]/[sub] function may wait here for fibres to finish. *)
  cancel : Cancel.t;
}

let is_finished t = Cancel.is_finished t.cancel

let check t =
  if is_finished t then invalid_arg "Switch finished!";
  Cancel.check t.cancel

let get_error t =
  Cancel.get_error t.cancel

let rec turn_off t ex =
  match t.cancel.state with
  | Finished -> invalid_arg "Switch finished!"
  | Cancelling (orig, _) when orig == ex || List.memq ex t.extra_exceptions -> ()
  | Cancelling _ ->
    begin match ex with
      | Cancel.Cancelled _ -> ()       (* The original exception will be reported elsewhere *)
      | Multiple_exn.T exns -> List.iter (turn_off t) exns
      | _ -> t.extra_exceptions <- ex :: t.extra_exceptions
    end
  | On _ ->
    Ctf.note_resolved t.id ~ex:(Some ex);
    Cancel.cancel t.cancel ex

let add_cancel_hook t hook = Cancel.add_hook t.cancel hook
let add_cancel_hook_unwrapped t hook = Cancel.add_hook_unwrapped t.cancel hook

let with_op t fn =
  check t;
  t.fibres <- t.fibres + 1;
  Fun.protect fn
    ~finally:(fun () ->
        t.fibres <- t.fibres - 1;
        if t.fibres = 0 then
          Waiters.wake_all t.waiter (Ok ())
      )

let await_internal waiters id (ctx:Suspend.context) enqueue =
  let cleanup_hooks = Queue.create () in
  let when_resolved r =
    Queue.iter Waiters.remove_waiter cleanup_hooks;
    Ctf.note_read ~reader:id ctx.tid;
    enqueue r
  in
  let cancel ex = when_resolved (Error ex) in
  let cancel_waiter = Cancel.add_hook ctx.cancel cancel in
  Queue.add cancel_waiter cleanup_hooks;
  let resolved_waiter = Waiters.add_waiter waiters (fun x -> when_resolved (Ok x)) in
  Queue.add resolved_waiter cleanup_hooks

(* Returns a result if the wait succeeds, or raises if cancelled. *)
let await waiters id =
  Suspend.enter (await_internal waiters id)

let or_raise = function
  | Ok x -> x
  | Error ex -> raise ex

let rec await_idle t =
  (* Wait for fibres to finish: *)
  while t.fibres > 0 do
    Ctf.note_try_read t.id;
    await t.waiter t.id |> or_raise;
  done;
  (* Call on_release handlers: *)
  let queue = Lwt_dllist.create () in
  Lwt_dllist.transfer_l t.on_release queue;
  let rec release () =
    match Lwt_dllist.take_opt_r queue with
    | None when t.fibres = 0 && Lwt_dllist.is_empty t.on_release -> ()
    | None -> await_idle t
    | Some fn ->
      begin
        try fn () with
        | ex -> turn_off t ex
      end;
      release ()
  in
  release ()

let await_idle t = Cancel.protect (fun _ -> await_idle t)

let raise_with_extras t ex bt =
  match t.extra_exceptions with
  | [] -> Printexc.raise_with_backtrace ex bt
  | exns -> Printexc.raise_with_backtrace (Multiple_exn.T (ex :: List.rev exns)) bt

let run fn =
  let id = Ctf.mint_id () in
  Ctf.note_created id Ctf.Switch;
  Cancel.sub @@ fun cancel ->
  let t = {
    id;
    fibres = 0;
    extra_exceptions = [];
    waiter = Waiters.create ();
    on_release = Lwt_dllist.create ();
    cancel;
  } in
  match fn t with
  | v ->
    await_idle t;
    begin match t.cancel.state with
      | Finished -> assert false
      | On _ ->
        (* Success. *)
        Ctf.note_read t.id;
        v
      | Cancelling (ex, bt) ->
        (* Function succeeded, but got failure waiting for fibres to finish. *)
        Ctf.note_read t.id;
        raise_with_extras t ex bt
    end
  | exception ex ->
    (* Main function failed.
       Turn the switch off to cancel any running fibres, if it's not off already. *)
    begin
      try turn_off t ex
      with Cancel.Cancel_hook_failed _ as ex ->
        t.extra_exceptions <- ex :: t.extra_exceptions
    end;
    await_idle t;
    Ctf.note_read t.id;
    match t.cancel.state with
    | On _ | Finished -> assert false
    | Cancelling (ex, bt) -> raise_with_extras t ex bt

let on_release_full t fn =
  match t.cancel.state with
  | On _ | Cancelling _ -> Lwt_dllist.add_r fn t.on_release
  | Finished ->
    match Cancel.protect fn with
    | () -> invalid_arg "Switch finished!"
    | exception ex -> raise (Multiple_exn.T [ex; Invalid_argument "Switch finished!"])

let on_release t fn =
  ignore (on_release_full t fn : _ Lwt_dllist.node)

let on_release_cancellable t fn =
  let node = on_release_full t fn in
  (fun () -> Lwt_dllist.remove node)
