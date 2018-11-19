(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017       .                                          *)
(*    Fabrice Le Fessant, OCamlPro SAS <fabrice@lefessant.net>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(* TODO: we don't handle correctly all the occurrences of Tfail, i.e.
   when an error occurs in a sub-part of a type and another type is expected,
   we should probably unify.
*)

(*
  Typecheck an AST.
 *)

open LiquidTypes

let noloc env = LiquidLoc.loc_in_file env.env.filename

let error loc msg =
  LiquidLoc.raise_error ~loc ("Type error:  " ^^ msg ^^ "%!")



let merge_lists l1 l2 =
  List.fold_left (fun l e ->
    if List.mem e l then l else e :: l
  ) l1 l2

let finalize_eqn = function
  | Tpartial (Peqn ([], loc)) -> error loc "No suitable overload\n"
  | Tpartial (Peqn ([(cl, rty)], _)) -> (*Printf.printf "Solved\n";*) rty, cl
  | Tpartial (Peqn _) as tx -> tx, []
  | _ as tx -> tx, []

let rec occurs tv = function
  | Tvar { tv = tv'; tyr } when Ref.isnull tyr -> tv = tv'
  | Tvar { tv = tv'; tyr } -> tv = tv' || occurs tv (Ref.get tyr)
  | Ttuple tyl -> List.exists (fun ty -> occurs tv ty) tyl
  | Toption ty | Tlist ty | Tset ty -> occurs tv ty
  | Tmap (ty1, ty2) | Tbigmap (ty1, ty2) | Tor (ty1, ty2)
  | Tlambda (ty1, ty2) -> occurs tv ty1 || occurs tv ty2
  | Tcontract c -> List.exists (fun e -> occurs tv e.parameter) c.entries_sig
  | Trecord (_, fl) | Tsum (_, fl)->List.exists (fun (_, ty) -> occurs tv ty) fl
  | Tclosure ((ty1, ty2), ty3) -> occurs tv ty1 || occurs tv ty2 ||occurs tv ty3
  | Tpartial (Peqn (el,_)) ->
    List.exists (fun (cl, rty) -> occurs tv rty ||
      List.exists (fun (ty1, ty2) -> occurs tv ty1 || occurs tv ty2) cl) el
  | Tpartial (Ptup al) -> List.exists (fun (_, ty) -> occurs tv ty) al
  | Tpartial (Pmap (ty1, ty2)) -> occurs tv ty1 || occurs tv ty2
  | Tpartial (Pcont el) -> List.exists (fun (_, ty) -> occurs tv ty) el
  | _ -> false

let print_loc loc =
  match loc.loc_pos with
  | Some ( (begin_line, begin_char) , (end_line, end_char) ) ->
    Printf.printf "%d.%d-%d.%d"
      begin_line begin_char
      end_line end_char
  | None ->
    Printf.printf "%s" loc.loc_file

let string_of_eqn (cl, rt) =
  let s = List.fold_left (fun s (tv, t) ->
    s ^ ((LiquidPrinter.Liquid.string_of_type t)) ^
    "=" ^ (LiquidPrinter.Liquid.string_of_type t) ^ " -> ") "" cl in
    s ^ (LiquidPrinter.Liquid.string_of_type rt)

(* let string_of_type_ex txr = match !txr with
 *   | (Teqn el, d) ->
 *      let s = "eqn (" ^ (string_of_int (Obj.magic txr)) ^ "), dep :" in
 *      let s = List.fold_left (fun s d -> s ^ " " ^ d) s d in
 *      List.fold_left (fun s e -> s ^ "\n  " ^ (string_of_eqn e)) s el
 *   | (Tunk, d) ->
 *      let s = "unk (" ^ (string_of_int (Obj.magic txr)) ^ "), dep :" in
 *      List.fold_left (fun s d -> s ^ " " ^ d) s d
 *   | (Ttup _, d) -> "tup"
 *   | (Tumap _, d) -> "map"
 *   | (Ttype t, _) -> (LiquidPrinter.Liquid.string_of_type t) ^ " (" ^
 *                       (string_of_int (Obj.magic txr)) ^ ")"
 * 
 * let string_of_type_ex_l txr = match !txr with
 *   | (Teqn el, d) -> "eqn"
 *   | (Tunk, d) -> "unk"
 *   | (Ttup _, d) -> "tup"
 *   | (Tumap _, d) -> "map"
 *   | (Ttype t, _) -> LiquidPrinter.Liquid.string_of_type t *)

let rec unify loc ty1 ty2 =

  match ty1, ty2 with
  | Tpartial _, Tpartial _ ->
    error loc "Anomaly : both Tpartial outside Tvar"
  | _, _ -> ();
  
  let uu = unify loc in

  (* Expand tvars *)
  let tyx1 = expand ty1 in
  let tyx2 = expand ty2 in

  (* print_loc loc;
   * Printf.printf ": Unify %s " (LiquidPrinter.Liquid.string_of_type ty1);
   * begin match ty1 with
   *   | Tvar _ -> Printf.printf "(%s) " (LiquidPrinter.Liquid.string_of_type tyx1)
   *   | _ -> () end;
   * Printf.printf "| %s " (LiquidPrinter.Liquid.string_of_type ty2);
   * begin match ty2 with
   *   | Tvar _ -> Printf.printf "(%s) " (LiquidPrinter.Liquid.string_of_type tyx2)
   *   | _ -> () end;
   * Printf.printf "\n"; *)

  (* Unify the types *)
  let tyx, to_unify = match tyx1, tyx2 with

    | Tvar { tyr = tyr1 }, Tvar { tyr = tyr2 } ->
      if not (Ref.isnull tyr1 && Ref.isnull tyr2) then
        failwith "Anomaly : non-null Tvar after expand";
      tyx1, []

    | Tvar { tv; tyr }, tyx | tyx, Tvar { tv; tyr } ->
      if not (Ref.isnull tyr) then
        failwith "Anomaly : non-null Tvar after expand";
      if occurs tv tyx then failwith "Cyclic vars";
      tyx, []


    | Tpartial Peqn (el1, l1), Tpartial Peqn (el2, l2) ->
      let el = List.fold_left (fun el (cl1, rty1) ->
        List.fold_left (fun el (cl2, rty2) ->
          if not (eq_types rty1 rty2) then el (* eqn do not contain tvars *)
          else (merge_lists cl1 cl2, rty1) :: el (*might duplicate constraints*)
        ) el el2
      ) [] el1 in
      Tpartial (Peqn (el, l1)) |> finalize_eqn

    | Tpartial Peqn (el, l), ty | ty, Tpartial Peqn (el, l) ->
      let el = List.filter (fun (_, rty) -> eq_types ty rty) el in
      Tpartial (Peqn (el, l)) |> finalize_eqn


    | Tpartial Ptup pl1, Tpartial Ptup pl2 ->
      let pl = List.fold_left (fun pl (n, ty2) ->
                 try let ty1 = List.assoc n pl in uu ty1 ty2; pl
                 with Not_found -> (n, ty2) :: pl
               ) pl1 pl2 in
      Tpartial (Ptup pl), []

    | Tpartial (Ptup pl), ty | ty, Tpartial (Ptup pl) ->
      begin match ty with
        | Ttuple tuple ->
          begin try
              List.iter (fun (n, ty) -> uu (List.nth tuple n) ty) pl;
              Ttuple tuple, []
            with Invalid_argument _ ->
              error loc ""
          end 
        | _ ->
          error loc "Partial tuple incompatible with %S"
            (LiquidPrinter.Liquid.string_of_type ty)
      end


    | Tpartial (Pmap (k_ty1, v_ty1)), Tpartial (Pmap (k_ty2, v_ty2)) ->
      uu k_ty1 k_ty2; uu v_ty1 v_ty2;
      Tpartial (Pmap (k_ty1, v_ty1)), []

    | Tpartial (Pmap (k_ty1, v_ty1)), ty
    | ty, Tpartial (Pmap (k_ty1, v_ty1)) ->
      begin match ty with
        | Tmap (k_ty2, v_ty2) | Tbigmap (k_ty2, v_ty2) ->
          uu k_ty1 k_ty2; uu v_ty1 v_ty2;
          ty, []
        | _ -> error loc "Undetermined map incompatible with %S"
                 (LiquidPrinter.Liquid.string_of_type ty)
      end


    | Tpartial (Pcont el1), Tpartial (Pcont el2) ->
      let el = List.fold_left (fun el (ep1, pty1) ->
        try let pty2 = List.assoc ep1 el in uu pty1 pty2; el
        with Not_found -> (ep1, pty1) :: el
      ) el1 el2 in
      Tpartial (Pcont el), []

    | Tpartial (Pcont el), ty | ty, Tpartial (Pcont el) ->
      begin match ty with
      | Tcontract { entries_sig } ->
        List.iter (fun (ep, pty) ->
          let entry = try
              List.find (fun e -> e.entry_name = ep) entries_sig
            with Not_found ->
              error loc "Contract has no entry point named %S"  ep in
          uu pty entry.parameter
        ) el;
        ty, []
      | _ -> error loc "Partial contract incompatible with %S"
             (LiquidPrinter.Liquid.string_of_type ty)
      end


    | Ttuple tl1, Ttuple tl2 ->
      begin try List.iter2 uu tl1 tl2;
        with Invalid_argument _ ->
          error loc "Tuples %S and %S have different arities"
            (LiquidPrinter.Liquid.string_of_type ty1)
            (LiquidPrinter.Liquid.string_of_type ty2)
      end;
      tyx1, []

    | Toption ty1, Toption ty2
    | Tlist ty1, Tlist ty2
    | Tset ty1, Tset ty2 ->
      uu ty1 ty2; tyx1, []

    | Tmap (k_ty1, v_ty1), Tmap (k_ty2, v_ty2)
    | Tbigmap (k_ty1, v_ty1), Tbigmap (k_ty2, v_ty2) ->
      uu k_ty1 k_ty2; uu v_ty1 v_ty2; tyx1, []

    | Tor (l_ty1, r_ty1), Tor (l_ty2, r_ty2) ->
      uu l_ty1 l_ty2; uu r_ty1 r_ty2; tyx1, []

    | Tlambda (from_ty1, to_ty1), Tlambda (from_ty2, to_ty2) ->
      uu from_ty1 from_ty2; uu from_ty1 from_ty2; tyx1, []

    | Tclosure ((from_ty1, env_ty1), to_ty1),
      Tclosure ((from_ty2, env_ty2), to_ty2) ->
      uu from_ty1 from_ty2; uu env_ty1 env_ty2; uu to_ty1 to_ty2; tyx1, []

    | Trecord (_, fl1), Trecord (_, fl2)
    | Tsum (_, fl1), Tsum (_, fl2) ->
      begin try
          List.iter2 (fun (_, ty1) (_, ty2) -> uu ty1 ty2) fl1 fl2;
        with Invalid_argument _ ->
          error loc "Types %S and %S have different arities"
            (LiquidPrinter.Liquid.string_of_type ty1)
            (LiquidPrinter.Liquid.string_of_type ty2)
      end;
      tyx1, []

    | Tcontract c1, Tcontract c2 ->
      let ok = try List.for_all2 (fun e1 e2 ->
        uu e1.parameter e2.parameter;
        e1.entry_name = e2.entry_name
      ) c1.entries_sig c2.entries_sig
      with Invalid_argument _ -> false in
      if not ok then
        error loc "Contracts signatures %S and %S are different"
          (LiquidPrinter.Liquid.string_of_type ty1)
          (LiquidPrinter.Liquid.string_of_type ty2)
      else
        tyx1, []

    | _, _ ->
      if not (eq_types tyx1 tyx2) then
        error loc "Types %s and %s are not compatible\n"
          (LiquidPrinter.Liquid.string_of_type tyx1)
          (LiquidPrinter.Liquid.string_of_type tyx2);
      tyx1, []
  in

  (* Update the type variables *)
  match ty1, ty2, tyx with
  | _, _, Tvar tv when not (Ref.isnull tv.tyr) -> failwith "Tvar after unify"
  | Tvar tv1, Tvar tv2, Tvar tv when Ref.isnull tv.tyr ->
      Ref.merge tv1.tyr tv2.tyr None
  | Tvar tv1, Tvar tv2, _ -> Ref.merge tv1.tyr tv2.tyr (Some tyx)
  | Tvar tv, _, _ | _, Tvar tv, _ -> Ref.set tv.tyr tyx
  | _ -> ();
  
  (* Printf.printf "After unify %s (%s) | %s (%s)\n\n"
   *   (LiquidPrinter.Liquid.string_of_type t1)
   *     (LiquidPrinter.Liquid.string_of_type (expand t1))
   *   (LiquidPrinter.Liquid.string_of_type t2)
   *   (LiquidPrinter.Liquid.string_of_type (expand t1)); *)

  (* Unify LHS of equations *)
  unify_list loc to_unify


and unify_list loc to_unify =
  List.iter (fun (ty1, ty2) ->
    unify loc ty1 ty2) to_unify


and resolve loc ty = match ty with
  | Tpartial (Peqn (el, l)) ->
     let el = List.fold_left (fun el (cl, rty) ->
       let cl, unsat = List.fold_left (fun (cl, unsat) (tv, ty) ->
         if unsat then (cl, unsat) else
         match expand tv with
         | Tpartial _ | Tvar _ -> ((tv, ty) :: cl, unsat)
         | ty' -> if eq_types ty ty' then (cl, unsat) else ([], true)
       ) ([], false) cl in
       if unsat then el else (cl, rty) :: el
     ) [] el in
     Tpartial (Peqn (el, l)) |> finalize_eqn
  | _ -> ty, []

let rec compat_types ty1 ty2 =
  (* Printf.printf "Compat %s (%s) / %s (%s) : "
   *   (LiquidPrinter.Liquid.string_of_type ty1)
   *   (LiquidPrinter.Liquid.string_of_type (expand ty1))
   *   (LiquidPrinter.Liquid.string_of_type ty2)
   *   (LiquidPrinter.Liquid.string_of_type (expand ty2)); *)
  let res = match expand ty1, expand ty2 with
  | Tvar _, _ | _, Tvar _ -> true
  | Tpartial (Peqn (el1, _)), Tpartial (Peqn (el2, _)) ->
    List.exists (fun (_, rty1) ->
      List.exists (fun (_, rty2) ->
        compat_types rty1 rty2) el2
    ) el1
  | Tpartial (Peqn (el, _)), ty | ty, Tpartial (Peqn (el, _)) ->
    List.exists (fun (_, rty) -> compat_types rty ty) el
  | _, _ -> eq_types ty1 ty2
  in
  (* Printf.printf "%b\n" res; *)
  res

let make_type_eqn loc env overloads params =
  (* Printf.printf "Make eqn :"; *)
  (* List.iter (fun p -> Printf.printf " %s (%s) "
   *               (LiquidPrinter.Liquid.string_of_type p)
   *               (LiquidPrinter.Liquid.string_of_type (expand p))) params;
   * Printf.printf "\n";
   * List.iter (fun (pl,rt) ->
   *   List.iter (fun p -> Printf.printf  "%s -> "
   *     (LiquidPrinter.Liquid.string_of_type p)) pl;
   *   Printf.printf "%s\n" (LiquidPrinter.Liquid.string_of_type rt)
   * ) overloads; *)
  let el = List.fold_left (fun eqn (opl, ort) -> (*Printf.printf "\n";*)
    let cl, unsat = List.fold_left2 (fun (cl, unsat) op p ->
      if unsat || eq_types op p then (cl, unsat)
      else match p with (* if expand, then Tvar below does not work*)
        | Tvar { tv } when compat_types op p -> ((p, op) :: cl, unsat)
        | _ -> ([], true)
    ) ([], false) opl params in
    if unsat then eqn else (cl, ort) :: eqn
  ) [] overloads in
  (* Printf.printf "%d overloads\n" (List.length el); *)
  let ty = Tpartial (Peqn (el, loc)) in
  let ty, to_unify = resolve loc ty in
  let ty = match ty with
  | Tpartial (Peqn _) -> (*Printf.printf "Not solved\n";*)
     Tvar { tv = fresh_tv (); tyr = Ref.create ty }
  | Tpartial _ -> failwith "Bad return type"
  | _ -> ty (* what if compound ? *)
  in
  unify_list loc to_unify;
  ty

let rec find_variant_type env = function
  | [] -> None
  | (CAny, _) :: cases -> find_variant_type env cases
  | (CConstr (("Left"|"Right"), _), _) :: _ ->
    Some (Tor (fresh_tvar (), fresh_tvar ()))
  | (CConstr (c, _), _) :: _ ->
    try let n, _ = find_constr c env.env in Some (find_type n env.env)
    with Not_found -> None

let rec has_tvar = function
  | Tvar _ -> true
  | Ttuple tyl -> List.exists has_tvar tyl
  | Toption ty | Tlist ty | Tset ty -> has_tvar ty
  | Tmap (ty1, ty2) | Tbigmap (ty1, ty2) | Tor (ty1, ty2)
  | Tlambda (ty1, ty2) -> has_tvar ty1 || has_tvar ty2
  | Tcontract c -> List.exists (fun e -> has_tvar e.parameter) c.entries_sig
  | Trecord (_, fl) | Tsum (_, fl) ->List.exists (fun (_, ty) -> has_tvar ty) fl
  | Tclosure ((ty1, ty2), ty3) -> has_tvar ty1 || has_tvar ty2 || has_tvar ty3
  | Tpartial _ -> failwith "has_tvar Tpartial TODO"
  | _ -> false

let rec get_type loc ty =
  let get_type = get_type loc in
  match ty with
  | Tvar { tv; tyr } when Ref.isnull tyr ->
     LiquidLoc.warn loc (ChangeToUnit tv);
     Tunit
  | Tvar { tv; tyr } ->
     begin match Ref.get tyr with
     | Tpartial (Ptup pl) ->
        let pl = List.sort (fun (i1, p1) (i2, p2) ->
                     Pervasives.compare i1 i2) pl in
        let _, pl = List.fold_left (fun (l, pl) (i, p) ->
                     if l = i then (l + 1, (get_type p) :: pl)
                     else begin
                         let plr = ref pl in
                         for c = l to i-1 do
                           plr := Tunit :: !plr
                         done;
                         l, !plr
                       end
                   ) (0, []) pl in
        LiquidLoc.warn loc (ChangeToTuple tv);
        Ttuple (List.rev pl)
     | Tpartial (Pmap (k_ty, v_ty)) ->
        LiquidLoc.warn loc (ChangeToMap tv);
        Tmap (get_type k_ty, get_type v_ty)
     | Tpartial (Pcont _) ->
         error loc "Unresolved contract %S" tv (* UnitContract ?*)
     | Tpartial (Peqn _) as ty ->
         let ty, to_unify = resolve loc ty in
         begin match ty with
           | Tpartial (Peqn (el, l)) -> (* pick first ?*)
             (* List.iter (fun e -> Printf.printf "%s\n" (string_of_eqn e)) el;
              * error l "Unresolved overload %S (%d)" tv (List.length el) *)
              error l "Unresolved overload, add annotations" tv
           | _ ->
             Ref.set tyr ty;
             unify_list loc to_unify;
             ty
         end
     | ty -> get_type ty
     end
  | Ttuple tyl -> Ttuple (List.map (get_type) tyl)
  | Toption ty -> Toption (get_type ty)
  | Tlist ty -> Tlist (get_type ty)
  | Tset ty -> Tset (get_type ty)
  | Tmap (tyk, tyv) -> Tmap (get_type tyk, get_type tyv)
  | Tbigmap (tyk, tyv) -> Tbigmap (get_type tyk, get_type tyv)
  | Tcontract c ->
     Tcontract { c with entries_sig =
                   List.map (fun e ->
                     { e with parameter = get_type e.parameter }
                   ) c.entries_sig }
  | Tor (ty1, ty2) -> Tor (get_type ty1, get_type ty2)
  | Tlambda (ty1, ty2) -> Tlambda (get_type ty1, get_type ty2)
  | Trecord (r, fl) ->
     Trecord (r, List.map (fun (f, ty) -> (f, get_type ty)) fl)
  | Tsum (s, cl) ->
     Tsum (s, List.map (fun (c, ty) -> (c, get_type ty)) cl)
  | Tclosure ((ty1, ty2), ty3) ->
     Tclosure ((get_type ty1, get_type ty2), get_type ty3)
  | _ -> ty

let rec process_exp (e:typed_exp) =
  let get_type = get_type e.loc in
  let desc = match e.desc with
    | Let lb -> Let { lb with bnd_val = process_exp lb.bnd_val;
                              body = process_exp lb.body }
    | Var s -> e.desc
    | SetField sf -> SetField { sf with record = process_exp sf.record;
                                        set_val = process_exp sf.set_val }
    | Project p -> Project { p with record = process_exp p.record }
    | Const c -> Const { c with ty = get_type c.ty }
    | Apply app -> Apply { app with args = List.map process_exp app.args }
    | If ite -> If { cond = process_exp ite.cond;
                     ifthen = process_exp ite.ifthen;
                     ifelse = process_exp ite.ifelse }
    | Seq (e1, e2) -> Seq (process_exp e1, process_exp e2)
    | Transfer tr -> Transfer { dest = process_exp tr.dest;
                                amount = process_exp tr.amount }
    | Call c -> Call { c with contract = process_exp c.contract;
                                         amount = process_exp c.amount;
                                         arg = process_exp c.arg }
    | MatchOption mo -> MatchOption { mo with arg = process_exp mo.arg;
                                           ifnone = process_exp mo.ifnone;
                                           ifsome = process_exp mo.ifsome }
    | MatchList ml -> MatchList { ml with arg = process_exp ml.arg;
                                          ifcons = process_exp ml.ifcons;
                                          ifnil = process_exp ml.ifnil }
    | Loop l -> Loop { l with body = process_exp l.body;
                              arg = process_exp l.arg  }
    | LoopLeft ll -> LoopLeft { ll with body = process_exp ll.body;
                                        arg = process_exp ll.arg;
                                        acc = match ll.acc with
                                          | Some e ->Some (process_exp e)
                                          | _ -> ll.acc }
    | Fold f -> Fold { f with body = process_exp f.body;
                              arg = process_exp f.arg;
                              acc = process_exp f.acc }
    | Map m -> Map { m with body = process_exp m.body ;
                            arg = process_exp m.arg }
    | MapFold mf -> MapFold { mf with body = process_exp mf.body;
                                      arg = process_exp mf.arg;
                                      acc = process_exp mf.acc }
    | Lambda l -> Lambda { l with arg_ty = get_type l.arg_ty ;
                                  body = process_exp l.body;
                                  ret_ty = get_type l.ret_ty }
    | Closure c -> Closure { c with arg_ty = get_type c.arg_ty ;
                                    call_env = List.map (fun (s, e) ->
                                      s, process_exp e) c.call_env ;
                                    body = process_exp c.body;
                                    ret_ty = get_type c.ret_ty }
    | Record r -> Record (List.map (fun (s, e) -> s, process_exp e) r)
    | Constructor c -> Constructor { c with arg = process_exp c.arg }
    | MatchVariant mv -> MatchVariant { arg = process_exp mv.arg;
                                        cases = List.map (fun (p, e) ->
                                          p, process_exp e) mv.cases }
    | MatchNat mn -> MatchNat { mn with arg = process_exp mn.arg;
                                        ifplus = process_exp mn.ifplus;
                                        ifminus = process_exp mn.ifminus }
    | Failwith e -> Failwith (process_exp e)
    | CreateContract cc ->
       CreateContract { args = List.map process_exp cc.args;
                        contract = process_contract e.loc cc.contract }
    | ContractAt ca -> ContractAt { arg = process_exp ca.arg;
                                    c_sig = ca.c_sig }
    | Unpack up -> Unpack { arg = process_exp up.arg;
                            ty = get_type up.ty }
    | TypeAnnot _ -> failwith "Remaining type annotation after typing"
    | Type _ -> failwith "Type TODO"
  in
  { e with desc = desc; ty = get_type e.ty }

and process_contract loc c =
  { c with values = List.map (fun (s, b, e) ->
                      s, b, process_exp e) c.values;
           entries = List.map (fun e ->
                       { entry_sig =
                           { e.entry_sig with parameter =
                               get_type loc e.entry_sig.parameter };
                         code = process_exp e.code }) c.entries }


(* Two types are comparable if they are equal and of a comparable type *)
let check_comparable loc prim ty1 ty2 =
  if not (comparable_type ty1 && eq_types ty1 ty2) then
    error loc "arguments of %s not comparable: %s\nwith\n%s\n"
      (LiquidTypes.string_of_primitive prim)
      (LiquidPrinter.Liquid.string_of_type ty1)
      (LiquidPrinter.Liquid.string_of_type ty2)

let new_binding env name ?(effect=false) ty =
  let count = ref 0 in
  let env = { env with
              vars = StringMap.add name (name, ty, effect) env.vars;
              vars_counts = StringMap.add name count env.vars_counts;
            } in
  (env, count)

let check_used env name count =
  if env.warnings && !count = 0 && name.nname.[0] <> '_' then begin
    LiquidLoc.warn name.nloc (Unused name.nname)
  end

let check_used_in_env env name =
  try
    let count = StringMap.find name.nname env.vars_counts in
    check_used env name count;
  with Not_found ->
  match env.clos_env with
  | None -> check_used env name (ref 0)
  | Some ce ->
    try
      let _, (count, _) = StringMap.find name.nname ce.env_bindings in
      check_used env name count;
    with Not_found ->
      check_used env name (ref 0)

(* Find variable name in either the global environment *)
let find_var ?(count_used=true) env loc name =
  try
    let (name, ty, effect) = StringMap.find name env.vars in
    let count = StringMap.find name env.vars_counts in
    if count_used then incr count;
    { (mk (Var name) ~loc ty) with effect }
  with Not_found ->
    error loc "unbound variable %S" name

(*let eq_exp env (e1 : typed_exp) (e2 : typed_exp) =
  let eq_var v1 v2 =
    let get v =
      try let (v, _, _) = StringMap.find v1 env.vars in v
      with Not_found -> error (noloc env) "unbound variable %S" v in
    get v1 = get v2 in
  eq_typed_exp eq_var e1 e2*)

let type_error loc msg actual expected =
  error loc "%s.\nExpected type:\n  %s\nActual type:\n  %s"
    msg
    (LiquidPrinter.Liquid.string_of_type expected)
    (LiquidPrinter.Liquid.string_of_type actual)


let error_prim loc prim args expected_args =
  let prim = LiquidTypes.string_of_primitive prim in
  let nargs = List.length args in
  let nexpected = List.length expected_args in
  if nargs <> nexpected then
    error loc "Prim %S: %d args provided, %d args expected"
      prim nargs nexpected
  else
    let args = List.map (fun { ty } -> ty) args in
    List.iteri (fun i (arg, expected) ->
        if arg <> expected then
          error loc
            "Primitive %s, argument %d:\nExpected type:%s\nProvided type:%s"
            prim (i+1)
            (LiquidPrinter.Liquid.string_of_type expected)
            (LiquidPrinter.Liquid.string_of_type arg)

      ) (List.combine args expected_args);
    Printf.eprintf "Fatal error on typechecking primitive %S\n%!" prim;
    assert false


(* Extract signature of contract, use previous name if the same
   signature was generated before otherwise use the same name as the
   contract for its signature *)
let sig_of_contract contract =
  let c_sig = sig_of_contract contract in
  let sig_name = StringMap.fold (fun name c_sig' -> function
      | Some _ as acc -> acc
      | None -> if eq_signature c_sig' c_sig then Some name else None
    ) contract.ty_env.contract_types None in
  let sig_name = match sig_name with
    | None -> Some contract.contract_name
    | Some _ -> sig_name in
  let c_sig = { c_sig with sig_name } in
  begin match sig_name with
    | None -> assert false
    | Some n ->
      contract.ty_env.contract_types <- StringMap.add n c_sig
          contract.ty_env.contract_types
  end;
  { f_sig_name = c_sig.sig_name;
    f_storage = contract.storage;
    f_entries_sig = c_sig.entries_sig }

(* Merge nested matches to recover encoding for pattern matching over
   sum type *)
let rec merge_matches acc loc cases constrs =
  match cases, constrs with
  | [ CConstr ("Left", l), case_l; CConstr ("Right", r), case_r ],
    [ c1, ty1; c2, ty2 ] ->
    List.rev @@ (CConstr (c2, r), case_r) ::
                (CConstr (c1, l), case_l) :: acc

  | [ CConstr ("Left", l), case_l;
      CConstr ("Right", [x]), { desc = Let { bnd_var = v; bnd_val = case_r;
                                             body = { desc = Var v' }}}],
    _ :: _
    when v.nname = v'
    ->
    merge_matches acc loc [ CConstr ("Left", l), case_l;
                            CConstr ("Right", [x]), case_r ] constrs

  | [ CConstr ("Left", l), case_l;
      CConstr ("Right", [x]), { desc =  Let { bnd_var = v; bnd_val = case_r;
                                              body = { desc = Const { const = CUnit } }}}],
    _ :: _ ->
    merge_matches acc loc [ CConstr ("Left", l), case_l;
                            CConstr ("Right", [x]), case_r ] constrs

  | [ CConstr ("Left", l), case_l; CConstr ("Right", [x]), case_r ],
    (c1, ty1) :: constrs ->
    begin match case_r.desc with
      | MatchVariant { arg = { desc = Var x' }; cases }
        when x = x' ->
        (* match arg with
           | Left l -> case_l
           | Right x -> match x with
                        | Left -> ...*)

        merge_matches ((CConstr (c1, l), case_l) :: acc) loc cases constrs
      | _ ->
        (* ==> match | C1 l -> case_l | _ -> case_r *)
        List.rev @@ (CAny, case_r) :: (CConstr (c1, l), case_l) :: acc
    end
  | _ -> raise Exit

(* Typecheck an expression. Returns a typed expression *)
let rec typecheck env ( exp : syntax_exp ) : typed_exp =
  let loc = exp.loc in
  let uu = unify loc in
  match exp.desc with

  | Const { ty; const } ->
    mk ?name:exp.name ~loc (Const { ty; const }) (ty:datatype)

  | Let { bnd_var; inline; bnd_val; body } ->
    let bnd_val = typecheck env bnd_val in
    if bnd_val.ty = Tfail then
      LiquidLoc.warn bnd_val.loc AlwaysFails;
    let (env, count) =
      new_binding env bnd_var.nname ~effect:exp.effect bnd_val.ty in
    let body = typecheck env body in
    let desc = Let { bnd_var; inline; bnd_val; body } in
    check_used env bnd_var count;
    mk ?name:exp.name ~loc desc body.ty

  | Var v -> find_var env loc v

  | Project { field; record } ->
    let record = typecheck env record in
    let ty = match expand record.ty with
      | Trecord (record_name, ltys) ->
        begin
          try List.assoc field ltys
          with Not_found ->
            error loc "label %s does not belong to type %s"
              field record_name;
        end
      | Tvar _ | Tpartial _ ->
         let ty_name, _, ty =
           try find_label field env.env
           with Not_found -> error loc "unbound record field %S" field
         in
         let record_ty = find_type ty_name env.env in
         uu record.ty record_ty; ty
      | rty ->
          error loc "not a record type: %s, has no field %s"
            (LiquidPrinter.Liquid.string_of_type rty)
            field
    in
    mk ?name:exp.name ~loc (Project { field; record }) ty

  | SetField { record; field; set_val } ->
    let record = typecheck env record in
    let exp_ty =
      let ty_name, _, ty =
        try find_label field env.env
        with Not_found -> error loc "unbound record field %S" field
      in
      let record_ty = find_type ty_name env.env in
      begin match expand record.ty with
        | Tvar _ | Tpartial _ -> uu record.ty record_ty
        | _ ->
          if not @@ eq_types record.ty record_ty then
            error loc "field %s does not belong to type %s" field
              (LiquidPrinter.Liquid.string_of_type record.ty)
      end;
      ty
    in
    let set_val = typecheck_expected "field update" env exp_ty set_val in
    mk ?name:exp.name ~loc (SetField { record; field; set_val }) record.ty

  | Seq (exp1, exp2) ->
    let exp1 = typecheck_expected "sequence" env Tunit exp1 in
    if exp1.ty = Tfail then LiquidLoc.warn exp1.loc AlwaysFails;
    let exp2 = typecheck env exp2 in
    let desc = Seq (exp1, exp2) in
    (* TODO: if not fail1 then remove exp1 *)
    mk ?name:exp.name ~loc desc exp2.ty

  | If { cond; ifthen; ifelse } ->
    let cond =
      typecheck_expected "if condition" env Tbool cond in
    let ifthen = typecheck env ifthen in
    let ifelse, ty =
      if ifthen.ty = Tfail then
        let ifelse = typecheck env ifelse in
        ifelse, ifelse.ty
      else
        let ifelse =
          typecheck_expected "else branch" env ifthen.ty ifelse in
        ifelse, ifthen.ty
    in
    let desc = If { cond; ifthen; ifelse } in
    mk ?name:exp.name ~loc desc ty

  | Transfer { dest; amount } ->
    let amount = typecheck_expected "transfer amount" env Ttez amount in
    let dest = typecheck_expected "transfer destination" env Tkey_hash dest in
    let desc = Transfer { dest; amount } in
    mk ?name:exp.name ~loc desc Toperation

  | Call { contract; amount; entry; arg } ->
    let amount = typecheck_expected "call amount" env Ttez amount in
    let contract = typecheck env contract in
    let entry' = match entry with None -> "main" | Some e -> e in
    begin
      match expand contract.ty with
      (* match contract.ty with *)
      | Tcontract contract_sig ->
        begin try
            let { parameter = arg_ty } =
              List.find (fun { entry_name } -> entry_name = entry')
                contract_sig.entries_sig in
            let arg = typecheck_expected "call argument" env arg_ty arg in
            if amount.transfer || contract.transfer || arg.transfer then
              error loc "transfer within transfer arguments";
            let desc = Call { contract; amount; entry; arg } in
            mk ?name:exp.name ~loc desc Toperation
          with Not_found ->
            error loc "contract has no entry point %s" entry';
        end
      | Tvar _ | Tpartial _ ->
        let arg = typecheck env arg in
        if amount.transfer || contract.transfer || arg.transfer then
          error loc "transfer within transfer arguments";
        uu contract.ty (Tpartial (Pcont [(entry', arg.ty)]));
        let desc = Call { contract; amount; entry; arg } in
        mk ?name:exp.name ~loc desc Toperation
      | ty ->
        error contract.loc
          "Bad contract type.\nExpected type:\n  'a contract\n\
           Actual type:\n  %s"
          (LiquidPrinter.Liquid.string_of_type ty)
    end

  (* contract.main (param) amount *)
  | Apply { prim = Prim_unknown;
            args = { desc = Project { field = entry; record = contract }} ::
                   [param; amount] }
    when match (typecheck env contract).ty with
      | Tcontract _ -> true
      | _ -> false
    ->
    typecheck env
      (mk (Call { contract; amount; entry = Some entry; arg = param })
         ~loc ())

  | Apply { prim = Prim_unknown;
            args = { desc = Var "Contract.call" } :: args } ->
    let nb_args = List.length args in
    if nb_args <> 3 || nb_args <> 4  then
      error loc
        "Contract.call expects 3 or 4 arguments, it was given %d arguments."
        nb_args
    else
      error loc "Bad syntax for Contract.call."

  (* Extended primitives *)
  | Apply { prim = Prim_unknown;
            args = { desc = Var prim_name } :: args }
    when StringMap.mem prim_name env.env.ext_prims ->
    let eprim = StringMap.find prim_name env.env.ext_prims in
    let targs, args = List.fold_left (fun (targs, args) a ->
        match a.desc, targs with
        | Type ty, _ -> (ty :: targs, args)
        | _, [] -> (targs, (typecheck env a) :: args)
        | _, _ -> error loc "Type arguments must come first"
      ) ([], []) (List.rev args) in
    let tsubst =
      try List.combine eprim.tvs targs
      with Invalid_argument _ ->
        error loc "Expecting %d type arguments, got %d\n"
          (List.length eprim.tvs) (List.length targs) in
    let atys = List.map (tv_subst tsubst) eprim.atys in
    let rty = tv_subst tsubst eprim.rty in
    let prim = Prim_extension (prim_name, eprim.effect, targs,
                               eprim.nb_arg, eprim.nb_ret, eprim.minst) in
    begin try List.iter2 (fun a aty ->
      match expand a.ty with
        | Tvar _ | Tpartial _ -> uu a.ty aty
        | _ ->
          if not (eq_types a.ty aty) then
            error loc "Bad %d args for primitive %S:\n    %s\n"
              (List.length args) (LiquidTypes.string_of_primitive prim)
              (String.concat "\n    " (List.map (fun arg ->
                   LiquidPrinter.Liquid.string_of_type arg.ty) args))
      ) args atys
    with Invalid_argument _ ->
      error loc "Primitive %S expects %d arguments, was given %d"
        (LiquidTypes.string_of_primitive prim)
        (List.length eprim.atys) (List.length args)
    end;
    mk ?name:exp.name ~loc (Apply { prim; args }) rty

  (* <unknown> (prim, args) -> prim args *)
  | Apply { prim = Prim_unknown;
            args = { desc = Var name } ::args }
    when not (StringMap.mem name env.vars) ->
    let prim =
      try
        LiquidTypes.primitive_of_string name
      with Not_found ->
        error loc "Unknown identifier %S" name
    in
    typecheck env { exp with
                    desc = Apply { prim; args } }

  (* <unknown> (f, x1, x2, x3) -> ((f x1) x2) x3) *)
  | Apply { prim = Prim_unknown; args = f :: ((_ :: _) as r) } ->
    let exp = List.fold_left (fun f x ->
        { exp with desc = Apply { prim = Prim_exec; args =  [x; f] }}
      ) f r
    in
    typecheck env exp

  | Apply { prim; args } ->
    typecheck_apply ?name:exp.name ~loc env prim loc args

  | Failwith arg ->
    let arg = typecheck env arg in
    mk (Failwith arg) ~loc Tfail (* no name *)

  | MatchOption { arg; ifnone; some_name; ifsome } ->
    let arg = typecheck env arg in
    let arg_ty = match expand arg.ty with
      | Tfail -> error loc "cannot match failure"
      | Toption ty -> ty
      | Tvar _ | Tpartial _ ->
         let ty = fresh_tvar () in
         uu arg.ty (Toption ty); ty
      | _ -> error loc "not an option type : %s" (LiquidPrinter.Liquid.string_of_type (expand arg.ty))
    in
    let ifnone = typecheck env ifnone in
    let (env, count) = new_binding env some_name.nname arg_ty in
    let ifsome = typecheck env ifsome in
    check_used env some_name count;
    let desc = MatchOption { arg; ifnone; some_name; ifsome } in
    let ty =
      match ifnone.ty, ifsome.ty with
      | ty, Tfail | Tfail, ty -> ty
      | ty1, ty2 when has_tvar ty1 || has_tvar ty2 ->
         uu ty1 ty2; ty1
      | ty1, ty2 ->
        if not @@ eq_types ty1 ty2 then
          type_error loc "branches of match have different types" ty2 ty1;
        ty1
    in
    mk ?name:exp.name ~loc desc ty

  | MatchNat { arg; plus_name; ifplus; minus_name; ifminus } ->
    let arg = typecheck_expected "match%nat" env Tint arg in
    let (env2, count_p) = new_binding env plus_name.nname Tnat in
    let ifplus = typecheck env2 ifplus in
    let (env3, count_m) = new_binding env minus_name.nname Tnat in
    let ifminus = typecheck env3 ifminus in
    check_used env plus_name count_p;
    check_used env minus_name count_m;
    let desc = MatchNat { arg; plus_name; ifplus; minus_name; ifminus } in
    let ty =
      match ifplus.ty, ifminus.ty with
      | ty, Tfail | Tfail, ty -> ty
      | ty1, ty2 when has_tvar ty1 || has_tvar ty2 ->
         uu ty1 ty2; ty1
      | ty1, ty2 ->
        if not @@ eq_types ty1 ty2 then
          type_error loc "branches of match%nat must have the same type"
            ty2 ty1;
        ty1
    in
    mk ?name:exp.name ~loc desc ty

  | Loop { arg_name; body; arg } ->
    let arg = typecheck env arg in
    if arg.ty = Tfail then error loc "Loop.loop arg is a failure";
    let (env, count) = new_binding env arg_name.nname arg.ty in
    let body =
      typecheck_expected "Loop.loop body" env (Ttuple [Tbool; arg.ty]) body in
    check_used env arg_name count;
    mk ?name:exp.name ~loc (Loop { arg_name; body; arg }) arg.ty

  | LoopLeft { arg_name; body; arg; acc = Some acc } ->
    let arg = typecheck env arg in
    let acc = typecheck env acc in
    let arg_ty = Ttuple [arg.ty; acc.ty] in
    let (env, count) = new_binding env arg_name.nname arg_ty in
    let body = typecheck env body in
    let res_ty = match body.ty with
      | ty when has_tvar ty || has_tvar arg_ty ->
         let left_ty = fresh_tvar () in
         let right_ty = fresh_tvar () in
         uu arg.ty left_ty;
         uu body.ty (Ttuple [Tor (left_ty, right_ty); acc.ty]);
         right_ty
      | Ttuple [Tor (left_ty, right_ty); acc_ty] ->
        if not @@ eq_types acc_ty acc.ty then
          error acc.loc
            "Loop.left accumulator must be %s, got %s"
            (LiquidPrinter.Liquid.string_of_type acc_ty)
            (LiquidPrinter.Liquid.string_of_type acc.ty);
        if not @@ eq_types left_ty arg.ty then
          error arg.loc
            "Loop.left argument must be %s, got %s"
            (LiquidPrinter.Liquid.string_of_type left_ty)
            (LiquidPrinter.Liquid.string_of_type arg.ty);
        right_ty
      | _ ->
        error loc
          "Loop.left body must be of type (('a, 'b) variant * 'c), \
           got %s instead" (LiquidPrinter.Liquid.string_of_type body.ty) in
    check_used env arg_name count;
    mk ?name:exp.name ~loc (LoopLeft { arg_name; body; arg; acc = Some acc })
      (Ttuple [res_ty; acc.ty])

  | LoopLeft { arg_name; body; arg; acc = None } ->
    let arg = typecheck env arg in
    let (env, count) = new_binding env arg_name.nname arg.ty in
    let body = typecheck env body in
    let res_ty = match body.ty with 
      | ty when has_tvar ty || has_tvar arg.ty ->
         let left_ty = fresh_tvar () in
         let right_ty = fresh_tvar () in
         uu arg.ty left_ty;
         uu body.ty (Tor (left_ty, right_ty));
         right_ty
      | Tor (left_ty, right_ty) ->
        if not @@ eq_types left_ty arg.ty then
          error arg.loc
            "Loop.left argument must be %s, got %s"
            (LiquidPrinter.Liquid.string_of_type left_ty)
            (LiquidPrinter.Liquid.string_of_type arg.ty);
        right_ty
      | _ ->
        error loc
          "Loop.left body must be of type ('a, 'b) variant, \
           got %s instead" (LiquidPrinter.Liquid.string_of_type body.ty) in
    check_used env arg_name count;
    mk ?name:exp.name ~loc (LoopLeft { arg_name; body; arg; acc = None }) res_ty

  (* For collections, replace generic primitives with their typed ones *)

  | Fold { prim; arg_name; body; arg; acc } ->
    let arg = typecheck env arg in
    let acc = typecheck env acc in
    let prim, arg_ty = match prim, arg.ty, acc.ty with

      | Prim_map_iter, ty, Tunit when has_tvar ty ->
         let k_ty = fresh_tvar () in
         let v_ty = fresh_tvar () in
         uu ty (Tmap (k_ty, v_ty));
         Prim_map_iter, Ttuple [k_ty; v_ty]
      | Prim_set_iter, ty, Tunit when has_tvar ty ->
         let elt_ty = fresh_tvar () in
         uu ty (Tset elt_ty);
         Prim_set_iter, elt_ty
      | Prim_list_iter, ty, Tunit when has_tvar ty ->
         let elt_ty = fresh_tvar () in
         uu ty (Tlist elt_ty);
         Prim_list_iter, elt_ty

      | Prim_map_fold, ty, acc_ty when (has_tvar ty || has_tvar acc_ty) ->
         let k_ty = fresh_tvar () in
         let v_ty = fresh_tvar () in
         let a_ty = fresh_tvar () in
         uu ty (Tmap (k_ty, v_ty));
         uu a_ty acc_ty;
         Prim_map_fold, Ttuple[Ttuple [k_ty; v_ty]; acc_ty]
      | Prim_set_fold, ty, acc_ty when (has_tvar ty || has_tvar acc_ty) ->
         let elt_ty = fresh_tvar () in
         let a_ty = fresh_tvar () in
         uu ty (Tset elt_ty);
         uu a_ty acc_ty;
         Prim_set_fold, Ttuple[elt_ty; acc_ty]
      | Prim_list_fold, ty, acc_ty when (has_tvar ty || has_tvar acc_ty) ->
         let elt_ty = fresh_tvar () in
         let a_ty = fresh_tvar () in
         uu ty (Tlist elt_ty);
         uu a_ty acc_ty;
         Prim_list_fold, Ttuple[elt_ty; acc_ty]

      | (Prim_coll_iter|Prim_map_iter), Tmap (k_ty, v_ty), Tunit ->
        Prim_map_iter, Ttuple [k_ty; v_ty]
      | (Prim_coll_iter|Prim_set_iter), Tset elt_ty, Tunit ->
        Prim_set_iter, elt_ty
      | (Prim_coll_iter|Prim_list_iter), Tlist elt_ty, Tunit ->
        Prim_list_iter, elt_ty

      | (Prim_map_fold|Prim_coll_fold), Tmap (k_ty, v_ty), acc_ty ->
        Prim_map_fold, Ttuple[Ttuple [k_ty; v_ty]; acc_ty]
      | (Prim_set_fold|Prim_coll_fold), Tset elt_ty, acc_ty ->
        Prim_set_fold, Ttuple[elt_ty; acc_ty]
      | (Prim_list_fold|Prim_coll_fold), Tlist elt_ty, acc_ty ->
        Prim_list_fold, Ttuple[elt_ty; acc_ty]

      | _ ->
        error arg.loc "%s expects a collection, got %s"
          (LiquidTypes.string_of_fold_primitive prim)
          (LiquidPrinter.Liquid.string_of_type arg.ty)
    in
    let (env, count) = new_binding env arg_name.nname arg_ty in
    let body = typecheck_expected
        (LiquidTypes.string_of_fold_primitive prim ^" body") env acc.ty body in
    check_used env arg_name count;
    mk ?name:exp.name ~loc (Fold { prim; arg_name; body; arg; acc }) acc.ty

  | Map { prim; arg_name; body; arg } ->
    let arg = typecheck env arg in
    let prim, arg_ty, k_ty = match prim, arg.ty with

      | Prim_map_map, ty when has_tvar ty ->
         let k_ty = fresh_tvar () in
         let v_ty = fresh_tvar () in
         uu ty (Tmap (k_ty, v_ty));
         Prim_map_map, Ttuple [k_ty; v_ty], Some k_ty
      | Prim_set_map, ty when has_tvar ty ->
         let elt_ty = fresh_tvar () in
         uu ty (Tset elt_ty);
         Prim_set_map, elt_ty, None
      | Prim_list_map, ty when has_tvar ty ->
         let elt_ty = fresh_tvar () in
         uu ty (Tlist elt_ty);
         Prim_list_map, elt_ty, None

      | (Prim_map_map|Prim_coll_map), Tmap (k_ty, v_ty) ->
        Prim_map_map, Ttuple [k_ty; v_ty], Some k_ty
      | (Prim_set_map|Prim_coll_map), Tset elt_ty ->
        Prim_set_map, elt_ty, None
      | (Prim_list_map|Prim_coll_map), Tlist elt_ty ->
        Prim_list_map, elt_ty, None
      | _ ->
        error arg.loc "%s expects a collection, got %s"
          (LiquidTypes.string_of_map_primitive prim)
          (LiquidPrinter.Liquid.string_of_type arg.ty)
    in
    let (env, count) = new_binding env arg_name.nname arg_ty in
    let body = typecheck env body in
    let ret_ty = match expand arg.ty with
      | Tmap (k_ty, _) -> Tmap (k_ty, body.ty)
      | Tset _ -> Tset body.ty
      | Tlist _ -> Tlist body.ty
      | Tvar _ | Tpartial _ ->
         begin match prim, k_ty with
         | Prim_map_map, Some k_ty -> Tmap (k_ty, body.ty)
         | Prim_set_map, None -> Tset body.ty
         | Prim_list_map, None -> Tlist body.ty
         | _ -> assert false
         end
      | _ -> assert false
    in
    check_used env arg_name count;
    mk ?name:exp.name ~loc (Map { prim; arg_name; body; arg }) ret_ty

  | MapFold { prim; arg_name; body; arg; acc } ->
    let arg = typecheck env arg in
    let acc = typecheck env acc in
    let prim, arg_ty, k_ty = match prim, arg.ty, acc.ty with

      | Prim_map_map_fold, ty, acc_ty when has_tvar ty ->
         let k_ty = fresh_tvar () in
         let v_ty = fresh_tvar () in
         uu ty (Tmap (k_ty, v_ty));
         Prim_map_map_fold, Ttuple[Ttuple [k_ty; v_ty]; acc_ty], Some k_ty
      | Prim_set_map_fold, ty, acc_ty when has_tvar ty ->
         let elt_ty = fresh_tvar () in
         uu ty (Tset elt_ty);
         Prim_set_map_fold, Ttuple[elt_ty; acc_ty], None
      | Prim_list_map_fold, ty, acc_ty when has_tvar ty ->
         let elt_ty = fresh_tvar () in
         uu ty (Tlist elt_ty);
         Prim_list_map_fold, Ttuple[elt_ty; acc_ty], None

      | (Prim_map_map_fold|Prim_coll_map_fold), Tmap (k_ty, v_ty), acc_ty ->
        Prim_map_map_fold, Ttuple[Ttuple [k_ty; v_ty]; acc_ty], Some k_ty
      | (Prim_set_map_fold|Prim_coll_map_fold), Tset elt_ty, acc_ty ->
        Prim_set_map_fold, Ttuple[elt_ty; acc_ty], None
      | (Prim_list_map_fold|Prim_coll_map_fold), Tlist elt_ty, acc_ty ->
        Prim_list_map_fold, Ttuple[elt_ty; acc_ty], None
      | _ ->
        error arg.loc "%s expects a collection, got %s"
          (LiquidTypes.string_of_map_fold_primitive prim)
          (LiquidPrinter.Liquid.string_of_type arg.ty)
    in
    let (env, count) = new_binding env arg_name.nname arg_ty in
    let body = typecheck env body in
    let body_r = match body.ty with
      | Ttuple [r; baccty] when has_tvar baccty || has_tvar acc.ty ->
         uu baccty acc.ty; r
      | Ttuple [r; baccty] when eq_types baccty acc.ty -> r
      | _ ->
        error body.loc
          "body of %s must be of type 'a * %s, but has type %s"
          (LiquidTypes.string_of_map_fold_primitive prim)
          (LiquidPrinter.Liquid.string_of_type acc.ty)
          (LiquidPrinter.Liquid.string_of_type body.ty)
    in
    let ret_ty = match expand arg.ty with
      | Tmap (k_ty, _) -> Tmap (k_ty, body_r)
      | Tset _ -> Tset body_r
      | Tlist _ -> Tlist body_r
      | Tvar _ | Tpartial _ ->
         begin match prim, k_ty with
         | Prim_map_map_fold, Some k_ty -> Tmap (k_ty, body_r)
         | Prim_set_map_fold, None -> Tset body_r
         | Prim_list_map_fold, None -> Tlist body_r
         | _ -> assert false
         end
      | _ -> assert false
    in
    check_used env arg_name count;
    mk ?name:exp.name ~loc (MapFold { prim; arg_name; body; arg; acc })
      (Ttuple [ret_ty; acc.ty])

  | MatchList { arg; head_name; tail_name; ifcons; ifnil } ->
    let arg = typecheck env arg in
    let arg_ty = match expand arg.ty with
      | Tfail -> error loc "cannot match failure"
      | Tlist ty -> ty
      | Tvar _ | Tpartial _ ->
         let ty = fresh_tvar () in
         uu arg.ty (Tlist ty); ty
      | _ -> error loc "not a list type"
    in
    let ifnil = typecheck env ifnil in
    let (env, count_head) = new_binding env head_name.nname arg_ty in
    let (env, count_tail) = new_binding env tail_name.nname (Tlist arg_ty) in
    let ifcons = typecheck env ifcons in
    check_used env head_name count_head;
    check_used env tail_name count_tail;
    let desc = MatchList { arg; head_name; tail_name; ifcons; ifnil } in
    let ty =
      match ifnil.ty, ifcons.ty with
      | ty, Tfail | Tfail, ty -> ty
      | ty1, ty2 when has_tvar ty1 || has_tvar ty2 ->
         uu ty1 ty2; ty1
      | ty1, ty2 ->
        if not @@ eq_types ty1 ty2 then
          type_error loc "branches of match must have the same type"
            ty2 ty1;
        ty1
    in
    mk ?name:exp.name ~loc desc ty

  | Lambda { arg_name; arg_ty; body; ret_ty; recursive = None } ->
    (* allow closures at typechecking, do not reset env *)
    let (env, arg_count) = new_binding env arg_name.nname arg_ty in
    let body = typecheck env body in
    check_used env arg_name arg_count;
    let desc =
      Lambda { arg_name; arg_ty; body; ret_ty = body.ty; recursive = None } in
    let ty = Tlambda (arg_ty, body.ty) in
    mk ?name:exp.name ~loc desc ty

  | Lambda { arg_name; arg_ty; body; ret_ty;
             recursive = (Some f as recursive) } ->
    let ty = Tlambda (arg_ty, ret_ty) in
    let (env, f_count) = new_binding env f ty in
    let (env, arg_count) = new_binding env arg_name.nname arg_ty in
    let body = typecheck_expected "recursive function body" env ret_ty body in
    check_used env arg_name arg_count;
    check_used env { nname = f; nloc = loc} f_count;
    let desc = Lambda { arg_name; arg_ty; body; ret_ty; recursive } in
    mk ?name:exp.name ~loc desc ty

  (* This cannot be produced by parsing *)
  | Closure _ -> assert false

  (* Records with zero elements cannot be parsed *)
  | Record [] -> assert false

  | Record (( (label, _) :: _ ) as lab_x_exp_list) ->
    let ty_name, _, _ =
      try find_label label env.env
      with Not_found -> error loc "unbound label %S" label
    in
    let record_ty = find_type ty_name env.env in
    let labels = match record_ty with
      | Trecord (_, rtys) -> List.map fst rtys
      | _ -> assert false in
    let fields = List.map (fun (label, exp) ->
        let ty_name', _, ty = try
            find_label label env.env
          with Not_found -> error loc "unbound label %S" label
        in
        if ty_name <> ty_name' then error loc "inconsistent list of labels";
        let exp = typecheck_expected ("label "^ label) env ty exp in
        (label, exp)
      ) lab_x_exp_list in
    (* order record fields wrt type *)
    let fields = List.map (fun l ->
        try List.find (fun (l', _) -> l = l') fields
        with Not_found -> error loc "label %s is not defined" l;
      ) labels in
    mk ?name:exp.name ~loc (Record fields) record_ty

  (* TODO
     | Constructor(loc, Constr constr, arg)
      when env.decompiling && not @@ StringMap.mem constr env.env.constrs ->
      (* intermediate unknown constructor, add it *)
      let ty_name = "unknown_constructors" in
      let arg = typecheck env arg in
      let constr_ty = match StringMap.find_opt ty_name env.env.types with
        | Some (Tsum (n, constrs)) -> Tsum (n, (constr, arg.ty) :: constrs)
        | Some _ -> assert false
        | None -> Tsum (ty_name, [constr, arg.ty])
      in
      env.env.constrs <-
        StringMap.add constr (ty_name, arg.ty) env.env.constrs;
      env.env.types <- StringMap.add ty_name constr_ty env.env.types;
      mk ?name:exp.name ~loc (Constructor(loc, Constr constr, arg)) constr_ty
  *)

  | Constructor { constr = Constr constr; arg } ->
    begin try
        let ty_name, arg_ty = find_constr constr env.env in
        let arg = typecheck_expected "construtor argument" env arg_ty arg in
        let constr_ty = find_type ty_name env.env in
        mk ?name:exp.name ~loc (Constructor { constr = Constr constr; arg })
          constr_ty
      with Not_found ->
        error loc "unbound constructor %S" constr
    end

  | Constructor { constr = Left right_ty; arg } ->
    let arg = typecheck env arg in
    let ty = Tor (arg.ty, right_ty) in
    mk ?name:exp.name ~loc (Constructor { constr = Left right_ty; arg }) ty

  | Constructor { constr = Right left_ty; arg } ->
    let arg = typecheck env arg in
    let ty = Tor (left_ty, arg.ty) in
    mk ?name:exp.name ~loc (Constructor { constr = Right left_ty; arg }) ty

  (* Typecheck and normalize pattern matching.
     - When decompiling, try to merge nested patterns
     - Order cases based on constructor order in type declaration
     - Merge wildcard patterns if they are compatible (keep at most one)  *)
  | MatchVariant { arg; cases } ->
    let untyped_arg = arg in
    let arg = typecheck env arg in
    let decoded = match arg.ty, env.decompiling with
      | Tsum (_, constrs), true ->
        (* allow loose typing when decompiling *)
        begin try
            let cases = merge_matches [] loc cases constrs in
            Some (typecheck env
                    { exp with
                      desc = MatchVariant { arg = untyped_arg; cases } })
          with Exit -> None
        end
      | _ -> None in
    begin match decoded with
      | Some exp -> exp
      | None ->
        let constrs, is_left_right =
          try
            match expand arg.ty with
            | Tfail ->
              error loc "cannot match failure"
            | Tsum (_, constrs) ->
              (List.map fst constrs, None)
            | Tor (left_ty, right_ty) ->
              (* Left, Right pattern matching *)
              (["Left"; "Right"], Some (left_ty, right_ty))
            | Tvar _ (* | Tpartial _ *) ->
              begin match find_variant_type env cases with
                | Some (Tsum (_, constrs) as ty) ->
                  uu arg.ty ty; (List.map fst constrs, None)
                | Some (Tor (left_ty, right_ty) as ty) ->
                  uu arg.ty ty; (["Left"; "Right"], Some (left_ty, right_ty))
                | _ -> error loc "not a variant type: %s"
                         (LiquidPrinter.Liquid.string_of_type arg.ty)
              end
            | _ -> raise Not_found
          with Not_found ->
            error loc "not a variant type: %s"
              (LiquidPrinter.Liquid.string_of_type arg.ty)
        in
        let expected_type = ref None in
        let cases_extra_constrs =
          List.fold_left (fun acc -> function
              | CAny, _ -> acc
              | CConstr (c, _), _ -> StringSet.add c acc
            ) StringSet.empty cases
          |> ref
        in
        (* Normalize cases:
           - match cases in order
           - one (at most) wildcard at the end *)
        let cases = List.map (fun constr ->
            let pat, body = find_case loc env constr cases in
            cases_extra_constrs := StringSet.remove constr !cases_extra_constrs;
            constr, pat, body
          ) constrs in
        let are_unbound vars body =
          let body_vars = LiquidBoundVariables.bv body in
          not (List.exists (fun v -> StringSet.mem v body_vars) vars) in
        let rec normalize acc rev_cases = match rev_cases, acc with
          | [], _ -> acc
          | (_, CAny, body1) :: rev_cases, [CAny, body2]
            when eq_syntax_exp body1 body2 ->
            normalize [CAny, body1] rev_cases
          | (_, CAny, body1) :: rev_cases, [CConstr (_, vars2), body2]
            when are_unbound vars2 body2 && eq_syntax_exp body1 body2 ->
            normalize [CAny, body1] rev_cases
          | (_, CConstr (_, vars1) , body1) :: rev_cases, [CAny, body2]
            when are_unbound vars1 body1 && eq_syntax_exp body1 body2 ->
            normalize [CAny, body1] rev_cases
          | (_, CConstr (_, vars1) , body1) :: rev_cases,
            [CConstr (_, vars2), body2]
            when are_unbound vars1 body1 && are_unbound vars2 body2 &&
                 eq_syntax_exp body1 body2 ->
            normalize [CAny, body1] rev_cases
          | (c1, CAny, body1) :: rev_cases, _ ->
            (* body1 <> body2 *)
            normalize ((CConstr (c1, []), body1) :: acc)  rev_cases
          | (_, CConstr (c1, vars1), body1) :: rev_cases, _ ->
            normalize ((CConstr (c1, vars1), body1) :: acc)  rev_cases
        in
        let cases = normalize [] (List.rev cases) in

        if not (StringSet.is_empty !cases_extra_constrs) then
          error loc "constructors %s do not belong to type %s"
            (String.concat ", " (StringSet.elements !cases_extra_constrs))
            (LiquidPrinter.Liquid.string_of_type arg.ty);

        let cases = List.map (fun (pat, e) ->
            let add_vars_env vars var_ty =
              match vars with
              | [] -> env, None
              | [ var ] ->
                let (env, count) = new_binding env var var_ty in
                env, Some count
              | _ ->
                error loc "cannot deconstruct constructor args"
            in
            let env, count_opt =
              match pat with
              | CConstr ("Left", vars) ->
                let var_ty = match is_left_right with
                  | Some (left_ty, _) -> left_ty
                  | None -> error loc "expected variant, got %s"
                              (LiquidPrinter.Liquid.string_of_type arg.ty) in
                add_vars_env vars var_ty
              | CConstr ("Right", vars) ->
                let var_ty = match is_left_right with
                  | Some (_, right_ty) -> right_ty
                  | None -> error loc "expected variant, got %s"
                              (LiquidPrinter.Liquid.string_of_type arg.ty) in
                add_vars_env vars var_ty
              | CConstr (constr, vars) ->
                let ty_name', var_ty =
                  try find_constr constr env.env
                  with Not_found -> error loc "unknown constructor %S" constr
                in
                (* if ty_name <> ty_name' then
                   error loc "inconsistent constructors"; *)
                add_vars_env vars var_ty
              | CAny -> env, None
            in
            let e =
              match !expected_type with
              | Some expected_type ->
                typecheck_expected "pattern matching branch" env expected_type e
              | None ->
                let e = typecheck env e in
                begin match e.ty with
                  | Tfail -> ()
                  | _ -> expected_type := Some e.ty
                end;
                e
            in
            begin match pat, count_opt with
              | CConstr (_, [var]), Some count ->
                check_used env { nname = var; nloc = loc} count
              | _ -> ()
            end;
            (pat, e)
          ) cases
        in

        let desc = MatchVariant { arg; cases } in
        let ty = match !expected_type with
          | None -> Tfail
          | Some ty -> ty
        in
        mk ?name:exp.name ~loc desc ty
    end

  | Unpack { arg; ty } ->
    let arg = typecheck_expected "Bytes.unpack argument" env Tbytes arg in
    let desc = Unpack { arg; ty } in
    mk ?name:exp.name ~loc desc (Toption ty)

  | ContractAt { arg; c_sig } ->
    let arg = typecheck_expected "Contract.at argument" env Taddress arg in
    let desc = ContractAt { arg; c_sig } in
    mk ?name:exp.name ~loc desc (Toption (Tcontract c_sig))

  | CreateContract { args; contract } ->
    let contract = typecheck_contract ~warnings:env.warnings
        ~decompiling:env.decompiling contract in
    begin match args with
    | [manager; delegate; spendable; delegatable; init_balance; init_storage] ->
      let manager = typecheck_expected "manager" env Tkey_hash manager in
      let delegate =
        typecheck_expected "delegate" env (Toption Tkey_hash) delegate in
      let spendable = typecheck_expected "spendable" env Tbool spendable in
      let delegatable =
        typecheck_expected "delegatable" env Tbool delegatable in
      let init_balance =
        typecheck_expected "initial balance" env Ttez init_balance in
      let init_storage = typecheck_expected "initial storage"
          env (lift_type contract.ty_env contract.storage) init_storage in
      let desc = CreateContract {
          args = [manager; delegate; spendable;
                  delegatable; init_balance; init_storage];
          contract } in
      mk ?name:exp.name ~loc desc (Ttuple [Toperation; Taddress])
    | _ ->
      error loc "Contract.create expects 7 arguments, was given %d"
        (List.length args)
    end

  | TypeAnnot { e; ty } ->
     typecheck_expected "annotated expression" env ty e

  | Type ty -> assert false (* Not supposed to be typechecked *)

and find_case loc env constr cases =
  match List.find_all (function
      | CAny, _ -> true
      | CConstr (cname, _), _ -> cname = constr
    ) cases
  with
  | [] ->
    error loc "non-exhaustive pattern. Constructor %s is not matched." constr
  | matched_case :: unused ->
    List.iter (function
        | CAny, _ -> ()
        | (CConstr _, (e : syntax_exp)) ->
          LiquidLoc.warn e.loc (UnusedMatched constr)
      ) unused;
    matched_case

and typecheck_prim1 env prim loc args =
  match prim, args with
  | Prim_tuple_get, [{ ty = tuple_ty };
                     { desc = Const { const = CInt n | CNat n }}] ->
    begin match expand tuple_ty with
      | Tpartial (Ptup _) | Tvar _ ->
        let ty = fresh_tvar () in
        let n = LiquidPrinter.int_of_integer n in
        unify loc tuple_ty (Tpartial (Ptup [(n, ty)]));
        prim, ty
      | _ ->
        let tuple = match expand tuple_ty with
          | Ttuple tuple -> tuple
          | Trecord (_, rtys) -> List.map snd rtys
          | _ -> error loc "get takes a tuple as first argument, got:\n%s"
                   (LiquidPrinter.Liquid.string_of_type tuple_ty)
        in
        let n = LiquidPrinter.int_of_integer n in
        let size = List.length tuple in
        if size <= n then error loc "get outside tuple";
        let ty = List.nth tuple n in
        prim, ty
    end

  | Prim_tuple_set, [{ ty = tuple_ty };
                     { desc = Const { const = CInt n | CNat n }};
                     { ty }] ->
    begin match expand tuple_ty with
      | Tpartial (Ptup _) | Tvar _ -> 
        let n = LiquidPrinter.int_of_integer n in
        unify loc tuple_ty (Tpartial (Ptup [(n, ty)]));
        prim, tuple_ty
      | _ ->
       let tuple = match expand tuple_ty with
         | Ttuple tuple -> tuple
         | Trecord (_, rtys) -> List.map snd rtys
         | _ -> error loc "set takes a tuple as first argument, got:\n%s"
                  (LiquidPrinter.Liquid.string_of_type tuple_ty)
       in
       let n = LiquidPrinter.int_of_integer n in
       let expected_ty = List.nth tuple n in
       let size = List.length tuple in
       if size <= n then error loc "set outside tuple";
       unify loc ty expected_ty;
       let ty = tuple_ty in
       (* let ty = if not (eq_types ty expected_ty || ty = Tfail) then
        *     error loc "prim set bad type"
        *   else tuple_ty
        * in *)
       prim, ty
    end

  | _ ->
    let prim =
      (* Unqualified versions of primitives. They should not be used,
         but they can be generated by decompiling Michelson. *)
      (* No inference needed here (types given by decompilation) *)
      match prim, args with
      | Prim_coll_update, [ _; _; { ty = Tset _ }] -> Prim_set_update
      | Prim_coll_update, [ _; _; { ty = (Tmap _ | Tbigmap _) }] ->
        Prim_map_update
      | Prim_coll_mem, [ _; { ty = Tset _ } ] -> Prim_set_mem
      | Prim_coll_mem, [ _; { ty = (Tmap _ | Tbigmap _) } ] -> Prim_map_mem
      | Prim_coll_find, [ _; { ty = (Tmap _ | Tbigmap _) } ] -> Prim_map_find
      | Prim_coll_size, [{ ty = Tlist _ } ] -> Prim_list_size
      | Prim_coll_size, [{ ty = Tset _ } ] -> Prim_set_size
      | Prim_coll_size, [{ ty = Tmap _ } ] -> Prim_map_size
      | Prim_coll_size, [{ ty = Tstring } ] -> Prim_string_size
      | Prim_coll_size, [{ ty = Tbytes } ] -> Prim_bytes_size
      | Prim_slice, [ _; _; { ty = Tstring } ] -> Prim_string_sub
      | Prim_slice, [ _; _; { ty = Tbytes } ] -> Prim_bytes_sub
      | Prim_concat, [{ ty = Tlist Tstring } ] -> Prim_string_concat
      | Prim_concat, [{ ty = Tlist Tbytes } ] -> Prim_bytes_concat
      | _ -> prim
    in
    prim, typecheck_prim2 env prim loc args

and typecheck_prim2 env prim loc args =
  if List.exists (fun a -> has_tvar a.ty) args then
    typecheck_prim2i env prim loc args
  else
    typecheck_prim2t env prim loc args

and typecheck_prim2i env prim loc args =
  let uu = unify loc in
  match prim, List.map (fun a -> a.ty) args with
  | (Prim_neq | Prim_lt | Prim_gt | Prim_eq | Prim_le | Prim_ge),
    [ ty1; ty2 ] ->
    let overloads = [ ([ Tbool; Tbool ], Tbool) ;
                      ([ Tint; Tint ], Tbool) ;
                      ([ Tnat; Tnat ], Tbool) ;
                      ([ Ttez; Ttez ], Tbool) ;
                      ([ Tstring; Tstring ], Tbool) ;
                      ([ Tbytes; Tbytes ], Tbool) ;
                      ([ Ttimestamp; Ttimestamp ], Tbool) ;
                      ([ Tkey_hash; Tkey_hash ], Tbool) ;
                      ([ Taddress; Taddress ], Tbool) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_compare, [ ty1; ty2 ] ->
    let overloads = [ ([ Tbool; Tbool ], Tint) ;
                      ([ Tint; Tint ], Tint) ;
                      ([ Tnat; Tnat ], Tint) ;
                      ([ Ttez; Ttez ], Tint) ;
                      ([ Tstring; Tstring ], Tint) ;
                      ([ Tbytes; Tbytes ], Tint) ;
                      ([ Ttimestamp; Ttimestamp ], Tint) ;
                      ([ Tkey_hash; Tkey_hash ], Tint) ;
                      ([ Taddress; Taddress ], Tint) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_neg, [ ty ] ->
    let overloads = [ ([ Tnat ], Tnat) ;
                      ([ Tint ], Tint)  ] in
    make_type_eqn loc env overloads [ ty ]

  | Prim_add, [ ty1; ty2 ] ->
    let overloads = [ ([ Ttez; Ttez ], Ttez) ;
                      ([ Tnat; Tnat ], Tnat) ;
                      ([ Tint; Tint ], Tint) ;
                      ([ Tnat; Tint ], Tint) ;
                      ([ Tint; Tnat ], Tint) ;
                      ([ Tint; Ttimestamp ], Ttimestamp) ;
                      ([ Tnat; Ttimestamp ], Ttimestamp) ;
                      ([ Ttimestamp; Tint ], Ttimestamp) ;
                      ([ Ttimestamp; Tnat ], Ttimestamp) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_sub, [ ty1; ty2 ] ->
    let overloads = [ ([ Ttez; Ttez ], Ttez) ;
                      ([ Tnat; Tnat ], Tint) ;
                      ([ Tint; Tint ], Tint) ;
                      ([ Tnat; Tint ], Tint) ;
                      ([ Tint; Tnat ], Tint) ;
                      ([ Ttimestamp; Tint ], Ttimestamp) ;
                      ([ Ttimestamp; Tnat ], Ttimestamp) ;
                      ([ Ttimestamp; Ttimestamp ], Ttimestamp) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_mul, [ ty1; ty2 ] ->
    let overloads = [ ([ Tnat; Ttez ], Ttez) ;
                      ([ Ttez; Tnat ], Ttez) ;
                      ([ Tnat; Tnat ], Tnat) ;
                      ([ Tint; Tint ], Tint) ;
                      ([ Tnat; Tint ], Tint) ;
                      ([ Tint; Tnat ], Tint) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_ediv, [ ty1; ty2 ] -> (*
     let overloads = [ ([ Ttez; Ttez ], Toption (Ttuple [Tnat; Ttez])) ;
                       ([ Ttez; Tnat ], Toption (Ttuple [Ttez; Ttez])) ;
                       ([ Tnat; Tnat ], Toption (Ttuple [Tnat; Tnat])) ;
                       ([ Tint; Tint ], Toption (Ttuple [Tint; Tnat])) ;
                       ([ Tnat; Tint ], Toption (Ttuple [Tint; Tnat])) ;
                       ([ Tint; Tnat ], Toption (Ttuple [Tint; Tnat])) ] in
     make_type_eqn loc env overloads [ ty1; ty2 ] *)
    let overloads = [ ([ Ttez; Ttez ], Tnat) ;
                      ([ Ttez; Tnat ], Ttez) ;
                      ([ Tnat; Tnat ], Tnat) ;
                      ([ Tint; Tint ], Tint) ;
                      ([ Tnat; Tint ], Tint) ;
                      ([ Tint; Tnat ], Tint) ] in
    let t1 = make_type_eqn loc env overloads [ ty1; ty2 ] in
    let overloads = [ ([ Ttez; Ttez ], Ttez) ;
                      ([ Ttez; Tnat ], Ttez) ;
                      ([ Tnat; Tnat ], Tnat) ;
                      ([ Tint; Tint ], Tnat) ;
                      ([ Tnat; Tint ], Tnat) ;
                      ([ Tint; Tnat ], Tnat) ] in
    let t2 = make_type_eqn loc env overloads [ ty1; ty2 ] in
    Toption (Ttuple [t1; t2])

  | (Prim_xor | Prim_or), [ ty1; ty2] ->
    let overloads = [ ([ Tbool; Tbool ], Tbool) ;
                      ([ Tnat; Tnat ], Tnat) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_and, [ ty1; ty2 ] ->
    let overloads = [ ([ Tbool; Tbool ], Tbool) ;
                      ([ Tint; Tnat ], Tnat) ;
                      ([ Tnat; Tnat ], Tnat) ] in
    make_type_eqn loc env overloads [ ty1; ty2 ]

  | Prim_not, [ ty ] ->
    let overloads = [ ([ Tbool ], Tbool) ;
                      ([ Tint ], Tint) ;
                      ([ Tnat ], Tint) ] in
    make_type_eqn loc env overloads [ty]

  | Prim_abs, [ ty ] -> uu ty Tint; Tint
  | Prim_is_nat, [ ty ] -> uu ty Tint; Toption Tnat
  | Prim_int, [ ty ] -> uu ty Tnat; Tint

  | Prim_sub, [ ty ] ->
    let overloads = [ ([ Tint ], Tint) ;
                      ([ Tnat ], Tint) ] in
    make_type_eqn loc env overloads [ty]

  | (Prim_lsl | Prim_lsr), [ ty1; ty2 ] -> uu ty1 Tnat; uu ty2 Tnat; Tnat

  | Prim_tuple, ty_args -> Ttuple (List.map (fun e -> e.ty) args)

  | Prim_map_add, [ key_ty; value_ty; map_ty ] ->
    uu map_ty (Tpartial (Pmap (key_ty, value_ty)));
    map_ty

  | Prim_map_update, [ key_ty; value_tyo; map_ty ] ->
    let value_ty = fresh_tvar () in
    uu value_tyo (Toption value_ty);
    uu map_ty (Tpartial (Pmap (key_ty, value_ty)));
    map_ty

  | Prim_map_remove, [ key_ty; map_ty ]
  | Prim_map_find, [ key_ty; map_ty ]
  | Prim_map_mem, [ key_ty; map_ty ] ->
    let value_ty = fresh_tvar () in
    uu map_ty (Tpartial (Pmap (key_ty, value_ty)));
    begin match prim with
      | Prim_map_remove -> map_ty
      | Prim_map_find -> Toption value_ty
      | Prim_map_mem -> Tbool
      | _ -> assert false
    end

  | (Prim_set_add | Prim_set_remove), [ key_ty; set_ty ]
  | Prim_set_update, [ key_ty; Tbool; set_ty ] -> (* should Tbool be unified ?*)
    uu set_ty (Tset key_ty); Tset key_ty

  | Prim_set_mem, [ key_ty; set_ty ] ->
    uu set_ty (Tset key_ty); Tbool

  | Prim_list_size, [ ty ] -> uu ty (Tlist (fresh_tvar ())); Tnat
  | Prim_set_size, [ ty ] -> uu ty (Tset (fresh_tvar ())); Tnat
  | Prim_map_size, [ ty ] ->
    uu ty (Tmap (fresh_tvar (), fresh_tvar ())); Tnat

  | Prim_Some, [ ty ] -> Toption ty

  | Prim_self, [ ty ] ->
    uu ty Tunit; Tcontract (sig_of_full_sig env.t_contract_sig)

  | Prim_now, [ ty ] -> uu ty Tunit; Ttimestamp
  | ( Prim_balance | Prim_amount ), [ ty ] -> uu ty Tunit; Ttez
  | ( Prim_source | Prim_sender ), [ ty ] -> uu ty Tunit; Taddress
  | Prim_gas, [ ty ] -> uu ty Tunit; Tnat

  | Prim_pack, [ ty ] -> (* No constraint on ty ? *)
    Tbytes

  | (Prim_blake2b | Prim_sha256 | Prim_sha512), [ ty ] ->
    uu ty Tbytes; Tbytes

  | Prim_hash_key, [ ty ] -> uu ty Tkey; Tkey_hash

  | Prim_check, [ ty1; ty2; ty3 ] ->
    uu ty1 Tkey; uu ty2 Tsignature; uu ty3 Tbytes; Tbool

  | Prim_address, [ ty ] ->
    uu ty (Tpartial (Pcont []));
    Taddress

  | Prim_create_account, [ ty1; ty2; ty3; ty4 ] ->
    uu ty1 Tkey_hash; uu ty2 (Toption Tkey_hash);
    uu ty3 Tbool; uu ty4 Ttez;
    Ttuple [Toperation; Taddress]

  | Prim_default_account, [ ty ] ->
    uu ty Tkey_hash; Tcontract unit_contract_sig

  | Prim_set_delegate, [ ty ] ->
    uu ty (Toption Tkey_hash); Toperation

  | Prim_exec,
    [ ty; (Tlambda(from_ty, to_ty) | Tclosure((from_ty, _), to_ty)) ] ->
    uu ty from_ty; to_ty
  (* more todo, infer TLambda / TClosure *)

  | Prim_list_rev, [ ty ] -> uu ty (Tlist (fresh_tvar ())); ty

  | Prim_concat_two, [ ty1; ty2 ] ->
    let overloads = [ ([ Tstring; Tstring ], Tstring) ;
                      ([ Tbytes; Tbytes ], Tbytes) ] in
    make_type_eqn loc env overloads [ty1;ty2]

  | Prim_string_concat, [ ty ] -> uu ty (Tlist Tstring); Tstring
  | Prim_bytes_concat, [ ty ] -> uu ty (Tlist Tbytes); Tbytes

  | Prim_Cons, [ head_ty; list_ty ] ->
    uu list_ty (Tlist head_ty); Tlist head_ty

  | Prim_string_size, [ ty ] -> uu ty Tstring; Tnat
  | Prim_bytes_size, [ ty ] -> uu ty Tbytes; Tnat

  | Prim_string_sub, [ ty1; ty2; ty3 ] ->
    uu ty1 Tnat; uu ty2 Tnat; uu ty3 Tstring; Toption Tstring

  | Prim_bytes_sub, [ ty1; ty2; ty3 ] ->
    uu ty1 Tnat; uu ty2 Tnat; uu ty3 Tbytes; Toption Tbytes

  | _ -> failwith ("typecheck_prim2i " ^
           (LiquidTypes.string_of_primitive prim) ^ " TODO")

and typecheck_prim2t env prim loc args =
  match prim, List.map (fun a -> a.ty) args with
  | ( Prim_neq | Prim_lt | Prim_gt | Prim_eq | Prim_le | Prim_ge ),
    [ ty1; ty2 ] ->
    check_comparable loc prim ty1 ty2;
    Tbool
  | Prim_compare,
    [ ty1; ty2 ] ->
    check_comparable loc prim ty1 ty2;
    Tint

  | Prim_neg, [( Tint | Tnat )] -> Tint

  | (Prim_add | Prim_sub) , [ Ttez; Ttez ] -> Ttez
  | Prim_mul, ([ Tnat; Ttez ] | [ Ttez; Tnat ]) -> Ttez

  | (Prim_add|Prim_mul), [ Tnat; Tnat ] -> Tnat
  | (Prim_add|Prim_sub|Prim_mul), [ (Tint|Tnat);
                                    (Tint|Tnat) ] -> Tint

  | Prim_add, [ Ttimestamp; Tint|Tnat ] -> Ttimestamp
  | Prim_add, [ Tint|Tnat; Ttimestamp ] -> Ttimestamp
  | Prim_sub, [ Ttimestamp; Tint|Tnat ] -> Ttimestamp
  | Prim_sub, [ Ttimestamp; Ttimestamp ] -> Tint

  (* TODO: improve types of ediv in Michelson ! *)
  | Prim_ediv, [ Tnat; Tnat ] ->
    Toption (Ttuple [Tnat; Tnat])
  | Prim_ediv, [ Tint|Tnat; Tint|Tnat ] ->
    Toption (Ttuple [Tint; Tnat])
  | Prim_ediv, [ Ttez; Tnat ] ->
    Toption (Ttuple [Ttez; Ttez])
  | Prim_ediv, [ Ttez; Ttez ] ->
    Toption (Ttuple [Tnat; Ttez])


  | Prim_xor, [ Tbool; Tbool ] -> Tbool
  | Prim_or, [ Tbool; Tbool ] -> Tbool
  | Prim_and, [ Tbool; Tbool ] -> Tbool
  | Prim_not, [ Tbool ] -> Tbool

  | Prim_xor, [ Tnat; Tnat ] -> Tnat
  | Prim_or, [ Tnat; Tnat ] -> Tnat
  | Prim_and, [ Tint|Tnat; Tnat ] -> Tnat
  | Prim_not, [ Tint|Tnat ] -> Tint

  | Prim_abs, [ Tint ] -> Tint
  | Prim_is_nat, [ Tint ] -> Toption Tnat
  | Prim_int, [ Tnat ] -> Tint
  | Prim_sub, [ Tint|Tnat ] -> Tint

  | (Prim_lsl|Prim_lsr), [ Tnat ; Tnat ] -> Tnat

  | Prim_tuple, ty_args -> Ttuple (List.map (fun e -> e.ty) args)

  | Prim_map_find,
    [ key_ty;
      (Tmap (expected_key_ty, value_ty) | Tbigmap (expected_key_ty, value_ty)) ]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Map.find key type";
    Toption value_ty
  | Prim_map_update,
    [ key_ty;
      Toption value_ty;
      ( Tmap (expected_key_ty, expected_value_ty)
      | Tbigmap (expected_key_ty, expected_value_ty)) as m]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Map.update key type";
    if not @@ eq_types expected_value_ty value_ty then
      error loc "bad Map.update value type";
    begin match m with
      | Tmap _ -> Tmap (key_ty, value_ty)
      | Tbigmap _ -> Tbigmap (key_ty, value_ty)
      |  _ -> assert false
    end
  | Prim_map_add,
    [ key_ty;
      value_ty;
      ( Tmap (expected_key_ty, expected_value_ty)
      | Tbigmap (expected_key_ty, expected_value_ty)) as m]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Map.add key type";
    if not @@ eq_types expected_value_ty value_ty then
      error loc "bad Map.add value type";
    begin match m with
      | Tmap _ -> Tmap (key_ty, value_ty)
      | Tbigmap _ -> Tbigmap (key_ty, value_ty)
      |  _ -> assert false
    end
  | Prim_map_remove,
    [ key_ty;
      ( Tmap (expected_key_ty, value_ty)
      | Tbigmap (expected_key_ty, value_ty)) as m]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Map.remove key type";
    begin match m with
      | Tmap _ -> Tmap (key_ty, value_ty)
      | Tbigmap _ -> Tbigmap (key_ty, value_ty)
      |  _ -> assert false
    end

  | Prim_map_mem,
    [ key_ty;
      (Tmap (expected_key_ty,_) | Tbigmap (expected_key_ty,_)) ]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Mem.mem key type";
    Tbool

  | Prim_set_mem,[ key_ty; Tset expected_key_ty]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Set.mem key type";
    Tbool

  | Prim_list_size, [ Tlist _]  ->  Tnat
  | Prim_set_size, [ Tset _]  ->  Tnat
  | Prim_map_size, [ Tmap _]  ->  Tnat

  | Prim_set_update, [ key_ty; Tbool; Tset expected_key_ty]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Set.update key type";
    Tset key_ty
  | Prim_set_add, [ key_ty; Tset expected_key_ty]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Set.add key type";
    Tset key_ty
  | Prim_set_remove, [ key_ty; Tset expected_key_ty]
    ->
    if not @@ eq_types expected_key_ty key_ty then
      error loc "bad Set.remove key type";
    Tset key_ty

  | Prim_Some, [ ty ] -> Toption ty
  | Prim_self, [ Tunit ] -> Tcontract (sig_of_full_sig env.t_contract_sig)
  | Prim_now, [ Tunit ] -> Ttimestamp
  | Prim_balance, [ Tunit ] -> Ttez
  | Prim_source, [ Tunit ] -> Taddress
  | Prim_sender, [ Tunit ] -> Taddress
  | Prim_amount, [ Tunit ] -> Ttez
  | Prim_gas, [ Tunit ] -> Tnat
  | Prim_pack, [ _ ] -> Tbytes
  | Prim_blake2b, [ Tbytes ] -> Tbytes
  | Prim_sha256, [ Tbytes ] -> Tbytes
  | Prim_sha512, [ Tbytes ] -> Tbytes
  | Prim_hash_key, [ Tkey ] -> Tkey_hash
  | Prim_check, [ Tkey; Tsignature; Tbytes ] ->
    Tbool
  | Prim_check, _ ->
    error_prim loc Prim_check args [Tkey; Tsignature; Tbytes]

  | Prim_address, [ Tcontract _ ] ->
    Taddress

  | Prim_create_account, [ Tkey_hash; Toption Tkey_hash; Tbool; Ttez ] ->
    Ttuple [Toperation; Taddress]
  | Prim_create_account, _ ->
    error_prim loc Prim_create_account args
      [ Tkey_hash; Toption Tkey_hash; Tbool; Ttez ]

  | Prim_default_account, [ Tkey_hash ] ->
    Tcontract unit_contract_sig

  | Prim_set_delegate, [ Toption Tkey_hash ] ->
    Toperation

  | Prim_exec, [ ty;
                 ( Tlambda(from_ty, to_ty)
                 | Tclosure((from_ty, _), to_ty))] ->
    if not @@ eq_types ty from_ty then
      type_error loc "Bad argument type in function application" ty from_ty;
    to_ty

  | Prim_list_rev, [ Tlist ty ] -> Tlist ty

  | Prim_concat_two, [ Tstring; Tstring ] -> Tstring
  | Prim_concat_two, [ Tbytes; Tbytes ] -> Tbytes
  | Prim_string_concat, [ Tlist Tstring ] -> Tstring
  | Prim_bytes_concat, [ Tlist Tbytes ] -> Tbytes

  | Prim_Cons, [ head_ty; Tunit ] ->
    Tlist head_ty
  | Prim_Cons, [ head_ty; Tlist tail_ty ] ->
    if not @@ eq_types head_ty tail_ty then
      type_error loc "Bad types for list" head_ty tail_ty;
    Tlist tail_ty

  | Prim_string_size, [ Tstring ] -> Tnat
  | Prim_bytes_size, [ Tbytes ] -> Tnat

  | Prim_string_sub, [ Tnat; Tnat; Tstring ] -> Toption Tstring
  | Prim_bytes_sub, [ Tnat; Tnat; Tbytes ] -> Toption Tbytes

  | prim, _ ->
    error loc "Bad %d args for primitive %S:\n    %s\n" (List.length args)
      (LiquidTypes.string_of_primitive prim)
      (String.concat "\n    "
         (List.map
            (fun arg ->
               LiquidPrinter.Liquid.string_of_type arg.ty)
            args))
    ;

and typecheck_expected info env expected_ty exp =
  let exp = typecheck env exp in
  if exp.ty <> Tfail then
    if has_tvar exp.ty || has_tvar expected_ty then
      unify exp.loc exp.ty expected_ty
    else if not @@ eq_types exp.ty expected_ty then
      type_error exp.loc
        ("Unexpected type for "^info) exp.ty expected_ty;
  exp

and typecheck_apply ?name env prim loc args =
  let args = List.map (typecheck env) args in
  let prim, ty = typecheck_prim1 env prim loc args in
  mk ?name (Apply { prim; args }) ty


and typecheck_entry env entry =
  (* let env = { env with clos_env = None } in *)
  (* register storage *)
  let (env, count_storage) =
    new_binding env entry.entry_sig.storage_name env.t_contract_sig.f_storage in
  (* register parameter *)
  let (env, count_param) =
    new_binding env entry.entry_sig.parameter_name entry.entry_sig.parameter in
  let expected_ty = Ttuple [Tlist Toperation; env.t_contract_sig.f_storage] in
  (* Code for entry point must be of type (operation list * storage) *)
  let code =
    typecheck_expected "return value" env expected_ty entry.code in
  let check_used v c =
    check_used env { nname = v; nloc = noloc env } c in
  check_used entry.entry_sig.parameter_name count_param;
  check_used entry.entry_sig.storage_name count_storage;
  { entry with code }

and typecheck_contract ~warnings ~decompiling contract =
  let env =
    {
      warnings;
      annot = false;
      decompiling;
      counter = ref 0;
      vars = StringMap.empty;
      vars_counts = StringMap.empty;
      to_inline = ref StringMap.empty;
      force_inline = ref StringMap.empty;
      env = contract.ty_env;
      clos_env = None;
      t_contract_sig = sig_of_contract contract;
    } in

  (* Add bindings to the environment for the global values *)
  let env, values, counts =
    List.fold_left (fun (env, values, counts) (name, inline, exp) ->
        let exp = typecheck env exp in
        let (env, count) = new_binding env name ~effect:exp.effect exp.ty in
        env, ((name, inline, exp) :: values), ((name, count) :: counts)
      ) (env, [], []) contract.values in
  (* Typecheck entries *)
  let entries = List.map (typecheck_entry env) contract.entries in
  (* Report unused global values *)
  List.iter (fun (name, count) ->
      check_used env { nname = name; nloc = noloc env } (* TODO *) count
    ) counts;
  let c_init = match contract.c_init with
    | None -> None
    | Some i ->
      let env, counts = List.fold_left (fun (env, counts) (arg, nloc, arg_ty) ->
          let (env, count) = new_binding env arg arg_ty in
          env, ({ nname = arg; nloc}, count) :: counts
        ) (env, []) i.init_args in
      let init_body = typecheck_expected "initial storage" env
          env.t_contract_sig.f_storage i.init_body in
      List.iter (fun (arg, count) ->
          check_used env arg count;
        ) counts;
      Some { i with init_body }
  in
  process_contract (List.hd contract.entries).code.loc { contract with
    values = List.rev values;
    entries;
    c_init }

let typecheck_code env ?expected_ty code =
  match expected_ty with
  | Some expected_ty -> typecheck_expected "value" env expected_ty code
  | None -> typecheck env code


(* XXX just for printing, do not use *)
let rec type_of_const = function
  | CUnit -> Tunit
  | CBool _ -> Tbool
  | CInt _ -> Tint
  | CNat _ -> Tnat
  | CTez _ -> Ttez
  | CTimestamp _ -> Ttimestamp
  | CString _ -> Tstring
  | CBytes _ -> Tbytes
  | CKey _ -> Tkey
  | CSignature _ -> Tsignature
  | CAddress _ -> Taddress
  | CTuple l ->
    Ttuple (List.map type_of_const l)
  | CNone -> Toption Tunit
  | CSome c -> Toption (type_of_const c)
  | CMap [] -> Tmap (Tint, Tunit)
  | CMap ((k,e) :: _) -> Tmap (type_of_const k, type_of_const e)

  | CBigMap [] -> Tbigmap (Tint, Tunit)
  | CBigMap ((k,e) :: _) -> Tbigmap (type_of_const k, type_of_const e)

  | CList [] -> Tlist (Tunit)
  | CList (e :: _) -> Tlist (type_of_const e)

  | CSet [] -> Tset (Tint)
  | CSet (e :: _) -> Tset (type_of_const e)

  | CLeft c -> Tor (type_of_const c, fresh_tvar () (* Tunit *))
  | CRight c -> Tor (fresh_tvar () (* Tunit *), type_of_const c)

  | CKey_hash _ -> Tkey_hash
  | CContract _ -> Tcontract unit_contract_sig

  (* XXX just for printing *)
  | CRecord _ -> Trecord ("<record>", [])
  | CConstr _ -> Tsum ("<sum>", [])


let check_const_type ?(from_mic=false) ~to_tez loc ty cst =
  let top_ty, top_cst = ty, cst in
  let rec check_const_type ty cst =
    match ty, cst with
    | Tunit, CUnit -> CUnit
    | Tbool, CBool b -> CBool b

    | Tint, CInt s
    | Tint, CNat s -> CInt s

    | Tnat, CInt s
    | Tnat, CNat s -> CNat s

    | Tstring, CString s -> CString s

    | Tbytes, CBytes s -> CBytes s

    | Ttez, CTez s -> CTez s

    | Tkey, CKey s -> CKey s
    | Tkey, CBytes s -> CKey s

    | Tkey_hash, CKey_hash s -> CKey_hash s
    | Tkey_hash, CBytes s -> CKey_hash s

    | Tcontract _, CContract s -> CContract s
    | Tcontract _, CAddress s -> CAddress s
    | Tcontract { entries_sig = [{ parameter= Tunit }] } , CKey_hash s ->
      CKey_hash s
    | Tcontract _, CBytes s -> CContract s

    | Taddress, CAddress s -> CAddress s
    | Taddress, CContract s -> CContract s
    | Taddress, CKey_hash s -> CKey_hash s
    | Taddress, CBytes s -> CContract s

    | Ttimestamp, CTimestamp s -> CTimestamp s

    | Tsignature, CSignature s -> CSignature s
    | Tsignature, CBytes s -> CSignature s

    | Ttuple tys, CTuple csts ->
      begin
        try
          CTuple (List.map2 check_const_type tys csts)
        with Invalid_argument _ ->
          error loc "constant type mismatch (tuple length differs from type)"
      end

    | Toption _, CNone -> CNone
    | Toption ty, CSome cst -> CSome (check_const_type ty cst)

    | Tor (left_ty, _), CLeft cst ->
      CLeft (check_const_type left_ty cst)

    | Tor (_, right_ty), CRight cst ->
      CRight (check_const_type right_ty cst)

    | Tmap (ty1, ty2), CMap csts ->
      CMap (List.map (fun (cst1, cst2) ->
          check_const_type ty1 cst1,
          check_const_type ty2 cst2) csts)

    | Tbigmap (ty1, ty2), (CMap csts | CBigMap csts) -> (* allow map *)
      CBigMap (List.map (fun (cst1, cst2) ->
          check_const_type ty1 cst1,
          check_const_type ty2 cst2) csts)

    | Tlist ty, CList csts ->
      CList (List.map (check_const_type ty) csts)

    | Tset ty, CSet csts ->
      CSet (List.map (check_const_type ty) csts)

    | Trecord (rname, labels), CRecord fields ->
      (* order record fields wrt type *)
      List.iter (fun (f, _) ->
          if not @@ List.mem_assoc f labels then
            error loc "Record field %s is not in type %s" f rname
        ) fields;
      let fields = List.map (fun (f, ty) ->
          try
            let cst = List.assoc f fields in
            f, check_const_type ty cst
          with Not_found ->
            error loc "Record field %s is missing" f
        ) labels in
      CRecord fields

    | Tsum (sname, constrs), CConstr (c, cst) ->
      CConstr (c,
               try
                 let ty = List.assoc c constrs in
                 check_const_type ty cst
               with Not_found ->
                 error loc "Constructor %s does not belong to type %s" c sname
              )

    | _ ->
      if from_mic then
        match ty, cst with
        | Ttimestamp, CString s ->
          begin (* approximation of correct tezos timestamp *)
            try Scanf.sscanf s "%_d-%_d-%_dT%_d:%_d:%_dZ%!" ()
            with _ ->
            try Scanf.sscanf s "%_d-%_d-%_d %_d:%_d:%_dZ%!" ()
            with _ ->
            try Scanf.sscanf s "%_d-%_d-%_dT%_d:%_d:%_d-%_d:%_d%!" ()
            with _ ->
            try Scanf.sscanf s "%_d-%_d-%_dT%_d:%_d:%_d+%_d:%_d%!" ()
            with _ ->
            try Scanf.sscanf s "%_d-%_d-%_d %_d:%_d:%_d-%_d:%_d%!" ()
            with _ ->
            try Scanf.sscanf s "%_d-%_d-%_d %_d:%_d:%_d+%_d:%_d%!" ()
            with _ ->
              error loc "Bad format for timestamp"
          end;
          CTimestamp s

        | Ttez, CString s -> CTez (to_tez s)
        | Tkey_hash, CString s -> CKey_hash s
        | Tcontract _, CString s -> CContract s
        | Tkey, CString s -> CKey s
        | Tsignature, CString s -> CSignature s

        | _ ->
          error loc "constant type mismatch, expected %s, got %s"
            (LiquidPrinter.Liquid.string_of_type top_ty)
            (LiquidPrinter.Liquid.string_of_type (type_of_const top_cst))
      else
        error loc "constant type mismatch, expected %s, got %s"
          (LiquidPrinter.Liquid.string_of_type top_ty)
          (LiquidPrinter.Liquid.string_of_type (type_of_const top_cst))

  in
  check_const_type ty cst
