signature hhsMinimize =
sig

  include Abbrev

  datatype Proof = 
    Tactic of (string * goal)
  | Then   of (Proof * Proof)
  | Thenl  of (Proof * Proof list)

  val pretty_mini_stac : real -> string -> goal -> goal list -> string
  val cosmetic_stac : string -> string
  val minimize : Proof -> Proof
  val reconstruct : goal -> Proof -> string
  
  
end
