signature hhsSearch =
sig

  include Abbrev
  
  type lbl_t = (string * real * goal * goal list)
  type fea_t = int list
  type feav_t = (lbl_t * fea_t)
  
  datatype proof_status_t = 
    ProofError | ProofSaturated | ProofTimeOut | Proof of string
  
  val last_stac : string ref
  
  val imperative_search   : 
    (int -> goal -> string list) ->
    (goal -> lbl_t list) ->
    (goal list -> real) ->
    (int -> goal -> string option) ->
    (string, tactic) Redblackmap.dict ->
    goal -> proof_status_t

end
