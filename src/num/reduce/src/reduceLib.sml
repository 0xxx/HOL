structure reduceLib :> reduceLib =
struct

open HolKernel Parse boolLib Boolconv Arithconv
     arithmeticTheory numeralTheory computeLib;

infix THEN |-> ;

fun failwith function = raise mk_HOL_ERR "reduceLib" function "";


(*-----------------------------------------------------------------------*)
(* RED_CONV - Try all the conversions in the library                     *)
(*-----------------------------------------------------------------------*)

val RED_CONV =
  let fun FAIL_CONV (s:string) tm = failwith s
  in
      Lib.itlist (Lib.curry (Conv.ORELSEC))
         [ADD_CONV,  AND_CONV,  BEQ_CONV,  COND_CONV, EVEN_CONV,
          DIV_CONV,  EXP_CONV,   GE_CONV,    GT_CONV, ODD_CONV,
          IMP_CONV,   LE_CONV,   LT_CONV,   MOD_CONV,
          MUL_CONV,  NEQ_CONV,  NOT_CONV,    OR_CONV,
          PRE_CONV,  SBC_CONV,  SUC_CONV] (FAIL_CONV "RED_CONV")
  end;

(*-----------------------------------------------------------------------*)
(* REDUCE_CONV - Perform above reductions at any depth.                  *)
(* Uses computeLib.                                                      *)
(*-----------------------------------------------------------------------*)

val NORM_0 = prove(Term `NUMERAL ALT_ZERO = 0`,
  REWRITE_TAC [arithmeticTheory.NUMERAL_DEF, arithmeticTheory.ALT_ZERO]);

val numeral_redns =
 lazyfy_thm arithmeticTheory.num_case_compute
  :: [numeral_distrib, numeral_eq, numeral_suc, numeral_pre, NORM_0,
      numeral_iisuc, numeral_add, numeral_mult, iDUB_removal,
      numeral_sub, numeral_lt, numeral_lte, iSUB_THM,
      numeral_exp, numeral_evenodd, iSQR, numeral_fact,MAX_DEF,MIN_DEF];

val div_thm =
    prove
      (Term ` !x y q r. x DIV y =
              if (x = q * y + r) /\ (r < y) then q else x DIV y `,
       REPEAT STRIP_TAC THEN COND_CASES_TAC THEN REWRITE_TAC [] THEN
       MATCH_MP_TAC DIV_UNIQUE THEN EXISTS_TAC (Term `r:num`) THEN
       ASM_REWRITE_TAC []);

val mod_thm =
    prove
      (Term `!x y q r. 
          x MOD y = if (x = q * y + r) /\ r<y then r else x MOD y`,
       REPEAT STRIP_TAC THEN COND_CASES_TAC THEN REWRITE_TAC [] THEN
       MATCH_MP_TAC MOD_UNIQUE THEN EXISTS_TAC (Term `q:num`) THEN
       ASM_REWRITE_TAC []);


fun dest_op opr =
 let val test = equal opr
 in fn tm =>
      let val (opr',arg) = strip_comb tm 
      in if test opr' then arg else raise Fail "dest_op"
      end
 end;

fun cbv_DIV_CONV tm =
  case dest_op numSyntax.div_tm tm
   of [x,y] => 
       (let open Arbnum numSyntax
            val (q,r) = divmod (dest_numeral x, dest_numeral y)
        in SPECL [x, y, mk_numeral q, mk_numeral r] div_thm
        end handle HOL_ERR _ => failwith "cbv_DIV_CONV")
    | otherwise => raise Fail "cbv_DIV_CONV";

fun cbv_MOD_CONV tm =
  case dest_op numSyntax.mod_tm tm
   of [x,y] => 
       (let open Arbnum numSyntax
            val (q,r) = divmod (dest_numeral x, dest_numeral y) 
        in SPECL [x, y, mk_numeral q, mk_numeral r] mod_thm
        end handle HOL_ERR _ => failwith "cbv_MOD_CONV")
    | otherwise => raise Fail "cbv_MOD_CONV";


fun num_compset () = 
  let open computeLib
      val compset = bool_compset()
      val _ = add_thms numeral_redns compset
      val _ = add_conv (numSyntax.div_tm, 2, cbv_DIV_CONV) compset
      val _ = add_conv (numSyntax.mod_tm, 2, cbv_MOD_CONV) compset
  in 
    compset
  end;


(*---------------------------------------------------------------------------
      Add numeral reductions to global compset
 ---------------------------------------------------------------------------*)

val _ = let open computeLib
        in add_funs numeral_redns;
           add_conv (numSyntax.div_tm, 2, cbv_DIV_CONV) the_compset;
           add_conv (numSyntax.mod_tm, 2, cbv_MOD_CONV) the_compset
        end;


(*-----------------------------------------------------------------------*)
(* REDUCE_{CONV,RULE,TAC} - conversions, rule and tactic versions of     *)
(* reduction.                                                            *)
(*-----------------------------------------------------------------------*)

local open computeLib
      val numcomps = num_compset() 
in 
  val REDUCE_CONV = CBV_CONV numcomps
end;

val REDUCE_RULE = Conv.CONV_RULE REDUCE_CONV;

val REDUCE_TAC = Tactic.CONV_TAC REDUCE_CONV;


end;
