(*---------------------------------------------------------------------------
     A special purpose version of make that "does the right thing" in
     single directories for building HOL theories, and accompanying
     SML libraries.
 ---------------------------------------------------------------------------*)

(* Copyright University of Cambridge, Michael Norrish, 1999-2001 *)
(* Author: Michael Norrish *)

(* magic to ensure that interruptions (SIGINTs) are actually seen by the
   linked executable as Interrupt exceptions *)
prim_val catch_interrupt : bool -> unit = 1 "sys_catch_break";
val _ = catch_interrupt true;

fun warn s = (TextIO.output(TextIO.stdErr, s); TextIO.flushOut TextIO.stdErr)

open Systeml;

(* Global parameters, which get set at configuration time *)
val HOLDIR0 = Systeml.HOLDIR;
val MOSMLDIR0 = Systeml.MOSMLDIR;
val DEPDIR = ".HOLMK";
val DEFAULT_OVERLAY = SOME "Overlay.ui";

val SYSTEML = Systeml.systeml

fun normPath s = Path.toString(Path.fromString s)
fun itlist f L base =
   let fun it [] = base | it (a::rst) = f a (it rst) in it L end;
fun itstrings f [] = raise Fail "itstrings: empty list"
  | itstrings f [x] = x
  | itstrings f (h::t) = f h (itstrings f t);
fun fullPath slist = normPath
   (itstrings (fn chunk => fn path => Path.concat (chunk,path)) slist);


val spacify =
   let fun enspace (x::(rst as _::_)) = x::" "::enspace rst
         | enspace l = l
   in String.concat o enspace
   end;

fun nspaces f n = if n <= 0 then () else (f " "; nspaces f (n - 1))

fun collapse_bslash_lines s = let
  val charlist = explode s
  fun trans [] = []
    | trans (#"\\"::(#"\n"::rest)) = trans rest
    | trans (x::xs) = x :: trans xs
in
  implode (trans charlist)
end

local val expand_backslash =
        String.translate (fn #"\\" => "\\\\" | ch => Char.toString ch)
in
fun quote s = String.concat["\"", expand_backslash s, "\""]
end;



(** Command line parsing *)

(*** list functions *)
fun butlast0 _ [] = raise Fail "butlast - empty list"
  | butlast0 acc [x] = List.rev acc
  | butlast0 acc (h::t) = butlast0 (h::acc) t
fun butlast l = butlast0 [] l

fun member m [] = false
  | member m (x::xs) = if x = m then true else member m xs
fun set_union s1 s2 =
  case s1 of
    [] => s2
  | (e::es) => let
      val s' = set_union es s2
    in
      if member e s' then s' else e::s'
    end
fun delete m [] = []
  | delete m (x::xs) = if m = x then delete m xs else x::delete m xs
fun set_diff s1 s2 = foldl (fn (s2e, s1') => delete s2e s1') s1 s2
fun remove_duplicates [] = []
  | remove_duplicates (x::xs) = x::(remove_duplicates (delete x xs))
fun alltrue [] = true
  | alltrue (x::xs) = x andalso alltrue xs
fun print_list0 [] = "]"
  | print_list0 [x] = x^"]"
  | print_list0 (x::xs) = x^", "^print_list0 xs
fun print_list l = "["^print_list0 l
fun I x = x

(*** parse command line *)
fun includify [] = []
  | includify (h::t) = "-I" :: h :: includify t

fun parse_command_line list = let
  fun find_pairs0 tag rem inc [] = (List.rev rem, List.rev inc)
    | find_pairs0 tag rem inc [x] = (List.rev (x::rem), List.rev inc)
    | find_pairs0 tag rem inc (x::(ys as (y::xs))) = let
      in
        if x = tag then
          find_pairs0 tag rem (y::inc) xs
        else
          find_pairs0 tag (x::rem) inc ys
      end
  fun find_pairs tag = find_pairs0 tag [] []
  fun find_toggle tag [] = ([], false)
    | find_toggle tag (x::xs) = let
      in
        if x = tag then (delete tag xs, true)
        else let val (xs', b) = find_toggle tag xs in
          (x::xs', b)
        end
      end
  fun find_alternative_tags [] input = (input, false)
    | find_alternative_tags (t1::ts) input = let
        val (rem0, b0) = find_toggle t1 input
        val (rem1, b1) = find_alternative_tags ts rem0
      in
        (rem1, b0 orelse b1)
      end

  fun find_one_pairtag tag nov somev list = let
    val (rem, vals) = find_pairs tag list
  in
    case vals of
      [] => (rem, nov)
    | [x] => (rem, somev x)
    | _ => let
        open TextIO
      in
        output(stdErr,"Ignoring all but last "^tag^" spec.\n");
        flushOut stdErr;
        (rem, somev (List.last vals))
      end
  end

  val (rem0, includes) = find_pairs "-I" list
  val (rem1, dontmakes) = find_pairs "-d" rem0
  val (rem2, debug) = find_toggle "--debug" rem1
  val (rem3, help) = find_alternative_tags  ["--help", "-h"] rem2
  val (rem4, show_version) = find_alternative_tags ["--version", "-v"] rem3
  val (rem5, rebuild_deps) = find_alternative_tags ["--rebuild_deps","-r"] rem4
  val (rem6, cmdl_HOLDIRs) = find_pairs "--holdir" rem5
  val (rem7, no_sigobj) = find_alternative_tags ["--no_sigobj", "-n"] rem6
  val (rem8, allfast) = find_toggle "--fast" rem7
  val (rem9, fastfiles) = find_pairs "-f" rem8
  val (rem10, qofp) = find_toggle "--qof" rem9
  val (rem11, no_hmakefile) = find_toggle "--no_holmakefile" rem10
  val (rem12, user_hmakefile) =
    find_one_pairtag "--holmakefile" NONE SOME rem11
  val (rem13, no_overlay) = find_toggle "--no_overlay" rem12
  val (rem14, user_overlay) = find_one_pairtag "--overlay" NONE SOME rem13
  val (rem15, cmdl_MOSMLDIRs) = find_pairs "--mosmldir" rem14
in
  {targets=rem15, debug=debug, show_usage=help, show_version=show_version,
   always_rebuild_deps=rebuild_deps,
   additional_includes=includes,
   dontmakes=dontmakes, no_sigobj = no_sigobj,
   quit_on_failure = qofp, no_hmakefile = no_hmakefile,
   allfast = allfast, fastfiles = fastfiles,
   user_hmakefile = user_hmakefile,
   no_overlay = no_overlay,
   user_overlay = user_overlay,
   cmdl_HOLDIR =
     case cmdl_HOLDIRs of
       []  => NONE
     | [x] => SOME x
     |  _  => let
       in
         warn "Ignoring all but last --holdir spec.\n";
         SOME (List.last cmdl_HOLDIRs)
       end,
   cmdl_MOSMLDIR =
     case cmdl_MOSMLDIRs of
       [] => NONE
     | [x] => SOME x
     | _ => let
       in
         warn "Ignoring all but last --mosmldir spec.\n";
         SOME (List.last cmdl_MOSMLDIRs)
       end}
end


(* parameters which vary from run to run according to the command-line *)
val {targets, debug, dontmakes, show_usage, show_version, allfast, fastfiles,
     always_rebuild_deps,
     additional_includes = cline_additional_includes,
     cmdl_HOLDIR, cmdl_MOSMLDIR,
     no_sigobj = cline_no_sigobj,
     quit_on_failure, no_hmakefile, user_hmakefile, no_overlay,
     user_overlay} =
  parse_command_line (CommandLine.arguments())

(* find HOLDIR by first looking at command-line, then looking for a
   value compiled into the code.
*)
val HOLDIR =
  case cmdl_HOLDIR of
    NONE => HOLDIR0
  | SOME s => s


val SIGOBJ    = normPath(Path.concat(HOLDIR, "sigobj"));
val UNQUOTER  = fullPath [HOLDIR, "bin/unquote"]
fun unquote_to file1 file2 = SYSTEML [UNQUOTER, file1, file2]

(* find MOSMLDIR by first looking at command-line, then looking for a
   value compiled into the code, and then for the environment variable
   MOSMLLIB.  This latter is set for Moscow ML's operation under
   Windows, and will lead us to the right place. *)
val MOSMLDIR =
  case cmdl_MOSMLDIR of
    NONE => MOSMLDIR0
  | SOME s => s

val MOSMLCOMP = fullPath [MOSMLDIR, "bin/mosmlc"]
fun compile debug args = let
  val _ = if debug then print ("  with command "^
                               spacify(MOSMLCOMP::args)^"\n")
          else ()
in
  SYSTEML (MOSMLCOMP:: args)
end;

val _ =
  if quit_on_failure andalso allfast then
    print "Warning: quit on (tactic) failure ignored for fast built theories"
  else
    ()

fun die_with message = let
  open TextIO
in
  output(stdErr, message ^ "\n");
  flushOut stdErr;
  Process.exit Process.failure
end

val hmakefile =
  case user_hmakefile of
    NONE => "Holmakefile"
  | SOME s =>
      if FileSys.access(s, [FileSys.A_READ]) then s
      else die_with ("Couldn't read/find makefile: "^s)

val hmakefile_doc =
  if FileSys.access(hmakefile, [FileSys.A_READ]) andalso not no_hmakefile
  then
    (if debug then
       print ("Reading additional information from "^hmakefile^"\n")
     else ();
     Holmake_rules.parse_from_file hmakefile)
  else Holmake_types.empty_doc

val hmake_prelims = #preliminaries hmakefile_doc
val hmake_includes = #includes hmake_prelims
val additional_includes =
  includify (remove_duplicates (cline_additional_includes @ hmake_includes))

val hmake_preincludes = includify (#pre_includes hmake_prelims)
val hmake_no_overlay = member "NO_OVERLAY" (#options hmake_prelims)
val hmake_no_sigobj = member "NO_SIGOBJ" (#options hmake_prelims)
val extra_cleans = #extra_cleans hmake_prelims

val actual_overlay =
  if no_overlay orelse hmake_no_overlay then NONE
  else
    case user_overlay of
      NONE => DEFAULT_OVERLAY
    | SOME s => let
      in
        case DEFAULT_OVERLAY of
          NONE =>
            die_with "Can't use overlays with this version of HOL."
        | SOME _ => user_overlay
      end


val extra_rules = #rules hmakefile_doc

fun extra_deps t =
  Option.map #dependencies (List.find (fn r => #target r = t) extra_rules)

fun extra_commands t =
  Option.map #commands (List.find (fn  r => #target r = t) extra_rules)

val extra_targets = map #target extra_rules

val no_sigobj = cline_no_sigobj orelse hmake_no_sigobj
val std_include_flags = if no_sigobj then [] else ["-I", SIGOBJ]

fun run_extra_command c =
  case c of
    [] => (* empty command; do nothing *) Process.success
  | (w0 :: ws) => let
      (* w0 subject to substitution *)
      (* idea for future : allow for special form of quotation around a
         file-name in ws to indicate that it should have the dq munging
         done on it *)
      val w_list =
        case w0 of
          "HOLMOSMLC" =>
            MOSMLCOMP :: "-q" :: (hmake_preincludes @ std_include_flags @
                                  additional_includes)
        | "HOLMOSMLC-C" => let
            val overlay_stringl =
              case actual_overlay of
                NONE => []
              | SOME s => [s]
          in
            MOSMLCOMP :: "-q" :: (hmake_preincludes @ std_include_flags @
                                  additional_includes @ ["-c"] @
                                  overlay_stringl)
          end
        | "MOSMLC" => MOSMLCOMP :: additional_includes
        | "MOSMLLEX" => [fullPath [MOSMLDIR, "bin/mosmllex"]]
        | "MOSMLYAC" => [fullPath [MOSMLDIR, "bin/mosmlyac"]]
        | _ => [w0]
    in
      TextIO.output(TextIO.stdOut, spacify c ^ "\n");
      TextIO.flushOut TextIO.stdOut;
      SYSTEML (w_list @ ws)
    end


fun run_extra_commands tgt commands =
  case commands of
    [] => Process.success
  | (c::cs) =>
      if run_extra_command c = Process.success then
        run_extra_commands tgt cs
      else
        (TextIO.output(TextIO.stdOut, "Failed. Couldn't build "^tgt^"\n");
         Process.failure)



val _ = if (debug) then let
in
  print ("HOLDIR = "^HOLDIR^"\n");
  print ("MOSMLDIR = "^MOSMLDIR^"\n");
  print ("Targets = "^print_list targets^"\n");
  print ("Additional includes = "^print_list additional_includes^"\n");
  print ("Using HOL sigobj dir = "^Bool.toString (not no_sigobj) ^"\n")
end else ()

(** Top level sketch of algorithm *)
(*

   We have the following relationship --> where this arrow should be read
   "leads to the production of in one step"

    *.sml --> *.uo                          [ mosmlc -c ]
    *.sig --> *.ui                          [ mosmlc -c ]
    *Script.uo --> *Theory.sig *Theory.sml
       [ running the *Script that can be produced from the .uo file ]

   (where I have included the tool that achieves the production of the
   result in []s)

   However, not all productions can go ahead with just the one principal
   dependency present.  Sometimes other files are required to be present
   too.  We don't know which other files which are required, but we can
   find out by using Ken's holdep tool.  (This works as follows: given the
   name of the principal dependency for a production, it gives us the
   name of the other dependencies that exist in the current directory.)

   In theory, we could just run holdep everytime we were invoked, and
   with a bit of luck we'll design things so it does look as if really
   are computing the dependencies every time.  However, this is
   unnecessary work as we can cache this information in files and just
   read it in from these.  Of course, this introduces a sub-problem of
   knowing that the information in the cache files is up-to-date, so
   we will need to compare time-stamps in order to be sure that the
   cached dependency information is up to date.

   Another problem is that we might need to build a dependency DAG but
   in a situation where elements of the principal dependency chain
   were themselves out of date.

   Rather than continually have to deal with strings corresponding to
   file-names and mess with nasty suffixes and the like, we define a
   structured datatype into which file-names can be translated once
   and for all.
*)

(** Definition of structured file type *)

datatype CodeType
    = Theory of string
    | Script of string
    | Other of string

datatype File
    = SML of CodeType
    | SIG of CodeType
    | UO of CodeType
    | UI of CodeType
    | Unhandled of string

fun string_part0 (Theory s) = s
  | string_part0 (Script s) = s
  | string_part0 (Other s) = s
fun string_part (UO c)  = string_part0 c
  | string_part (UI c)  = string_part0 c
  | string_part (SML c) = string_part0 c
  | string_part (SIG c) = string_part0 c
  | string_part (Unhandled s) = s

fun isProperSuffix s1 s2 = let
  val sz1 = size s1
  val sz2 = size s2
  open Substring
in
  if sz1 >= sz2 then NONE
  else let
    val (prefix, suffix) = splitAt(all s2, sz2 - sz1)
  in
    if string suffix = s1 then SOME (string prefix) else NONE
  end
end

fun split_file s = let
  open Substring
  val (base, ext) = splitr (fn c => c <> #".") (all s)
in
  if (size base <> 0) then
    (string (slice(base, 0, SOME (size base - 1))), string ext)
  else
    (s, "")
end

fun toCodeType s = let
  val possprefix = isProperSuffix "Theory" s
in
  if (isSome possprefix) then Theory (valOf possprefix)
  else let
    val possprefix = isProperSuffix "Script" s
  in
    if isSome possprefix then Script (valOf possprefix)
    else Other s
  end
end

fun toFile s0 =
  case split_file s0 of
    (s, "sml") => SML (toCodeType s)
  | (s, "sig") => SIG (toCodeType s)
  | (s, "uo")  => UO (toCodeType s)
  | (s, "ui")  => UI (toCodeType s)
  |    _       => Unhandled s0

fun codeToString c =
  case c of
    Theory s => s ^ "Theory"
  | Script s => s ^ "Script"
  | Other s  => s

fun fromFile f =
  case f of
    UO c  => codeToString c ^ ".uo"
  | UI c  => codeToString c ^ ".ui"
  | SIG c => codeToString c ^ ".sig"
  | SML c => codeToString c ^ ".sml"
  | Unhandled s => s

fun file_compare (f1, f2) = String.compare (fromFile f1, fromFile f2)

(** Construction of the dependency graph
    ------------------------------------

   The first thing to do is to define a type that will store our
   dependency graph:

*)

(*** Construct primary dependencies *)
(* Next, construct the primary dependency chain, for a given target *)
fun primary_dependent f =
    case f of
      UO c => SOME (SML c)
    | UI c => SOME (SIG c)
    | SML (Theory s) => SOME (SML (Script s))
    | SIG (Theory s) => SOME (SML (Theory s))
    | _ => NONE

(*** Construction of secondary dependencies *)

fun mk_depfile_name s = fullPath [DEPDIR, s^".d"]

(**** runholdep *)
(* The primary dependency chain does not depend on anything in the
   file-system; it always looks the same.  However, additional
   dependencies depend on what holdep tells us.  This function that
   runs holdep, and puts the output into specified file, which will live
   in DEPDIR somewhere. *)

exception HolDepFailed
fun runholdep arg destination_file = let
  open Mosml
  val _ = print ("Analysing "^fromFile arg^"\n")
  val result =
    Success(Holdep.main extra_targets debug
                        (std_include_flags @ additional_includes @
                         [fromFile arg]))
    handle _ => (print "Holdep failed.\n"; Failure "")
  fun myopen s =
    if FileSys.access(DEPDIR, []) then
      if FileSys.isDir DEPDIR then TextIO.openOut s
      else die_with ("Want to put dependency information in directory "^
                     DEPDIR^", but it already exists as a file")
    else
     (print ("Trying to create directory "^DEPDIR^" for dependency files\n");
      FileSys.mkDir DEPDIR;
      TextIO.openOut s
     )
  fun write_result_to_file s = let
    open TextIO
    val destin = normPath destination_file
    (* val _ = print ("destination: "^quote destin^"\n") *)
    val outstr = myopen destin
  in
    output(outstr, s);
    closeOut outstr
  end
in
  case result of
    Success s => write_result_to_file s
  | Failure s => raise HolDepFailed
end

(* a function that given a product file, figures out the argument that
   should be passed to runholdep in order to get back secondary
   dependencies. *)

fun holdep_arg (UO c) = SOME (SML c)
  | holdep_arg (UI c) = SOME (SIG c)
  | holdep_arg (SML (Theory s)) = SOME (SML (Script s))
  | holdep_arg (SIG (Theory s)) = SOME (SML (Script s))
  | holdep_arg _ = NONE

(**** get dependencies from file *)
(* pull out a list of files that target depends on from depfile.  *)
(* All files on the right of a colon are assumed to be dependencies.
   This is despite the fact that holdep produces two entries when run
   on fooScript.sml files, one for fooScript.uo, and another for fooScript
   itself, we actually want all of those dependencies in one big chunk
   because the production of fooTheory.{sig,sml} is now done as one
   atomic step from fooScript.sml. *)
fun first f [] = NONE
  | first f (x::xs) = let
      val res = f x
    in
      if isSome res then res else first f xs
    end

fun get_dependencies_from_file depfile = let
  fun get_whole_file s = let
    open TextIO
    val instr = openIn (normPath s)
  in
    inputAll instr before closeIn instr
  end
  fun parse_result s = let
    val lines = String.fields (fn c => c = #"\n") (collapse_bslash_lines s)
    fun process_line line = let
      val (lhs0, rhs0) = Substring.splitl (fn c => c <> #":")
                                          (Substring.all line)
      val lhs = Substring.string lhs0
      val rhs = Substring.string (Substring.slice(rhs0, 1, NONE))
        handle Subscript => ""
    in
      String.tokens Char.isSpace rhs
    end
    val result = List.concat (map process_line lines)
  in
    List.map toFile result
  end
in
  parse_result (get_whole_file depfile)
end

(**** get_dependencies *)
(* figures out whether or not a dependency file is a suitable place to read
   information about current target or not, and then either does so, or makes
   the dependency file and then reads from it.

     f1 forces_update_of f2
     iff
     f1 exists /\ (f2 exists ==> f1 is newer than f2)
*)

infix forces_update_of
fun (f1 forces_update_of f2) = let
  open Time
in
  FileSys.access(f1, []) andalso
  (not (FileSys.access(f2, [])) orelse FileSys.modTime f1 > FileSys.modTime f2)
end

fun get_direct_dependencies (f : File) : File list = let
  val fname = fromFile f
  val arg = holdep_arg f  (* arg is file to analyse for dependencies *)
in
  if isSome arg then let
    val arg = valOf arg
    val argname = fromFile arg
    val depfile = mk_depfile_name argname
    val _ =
      if always_rebuild_deps orelse argname forces_update_of depfile then
        runholdep arg depfile
      else ()
    val phase1 =
      (* circumstances can arise in which the dependency file won't be
         built, and won't exist; mainly because the file we're trying to
         compute dependencies for doesn't exist either.  In this case, we
         can only return the empty list *)
      if FileSys.access (depfile, [FileSys.A_READ]) then
        get_dependencies_from_file depfile
      else
        []
  in
    case f of
      UO x =>
        if
          FileSys.access(fromFile (SIG x), []) andalso
          List.all (fn f => f <> SIG x) phase1
        then
          UI x :: phase1
        else
          phase1
    | _ => phase1
  end
  else
    []
end

fun get_dependencies (f : File) : File list = let
in
  case (extra_deps (fromFile f)) of
    SOME l => map toFile l
  | NONE => let
      val file_dependencies0 = get_direct_dependencies f
      val file_dependencies =
        case actual_overlay of
          NONE => file_dependencies0
        | SOME s => if isSome (holdep_arg f) then
                      toFile (fullPath [SIGOBJ, s]) :: file_dependencies0
                    else
                      file_dependencies0
    in
      case f of
        SML (Theory x) => let
          (* there may be theory files mentioned in the Theory.sml file that
             aren't mentioned in the script file.  If so, we are really
             dependent on these, and should add them.  They will be listed
             in the dependencies for UO (Theory x). *)
          val additional_theories =
            if FileSys.access(fromFile f, [FileSys.A_READ]) then
              List.mapPartial (fn (x as (UO (Theory s))) => SOME x | _ => NONE)
              (get_dependencies (UO (Theory x)))
            else
              []

          val firstcut = set_union file_dependencies additional_theories
          (* because we have to build an executable in order to build a
             theory, this build depends on all of the dependencies
             (meaning the transitive closure of the direct dependency
             relation) in their .UO form, not just .UI *)
          fun collect_all_dependencies sofar tovisit =
            case tovisit of
              [] => sofar
            | (f::fs) => let
                val deps =
                  if Path.dir (string_part f) <> "" then []
                  else
                    case f of
                      UI x => (get_direct_dependencies f @
                               get_direct_dependencies (UO x))
                    | _ => get_direct_dependencies f
                val newdeps = set_diff deps sofar
              in
                collect_all_dependencies (sofar @ newdeps)
                                         (set_union newdeps fs)
              end
          val alldeps = collect_all_dependencies [] [f]
          val uo_deps =
            List.mapPartial (fn (UI x) => SOME (UO x) | _ => NONE) alldeps
        in
          set_union uo_deps (set_union alldeps firstcut)
        end
      | _ => file_dependencies
    end
end

(** Build graph *)

datatype buildcmds = MOSMLC
                   | BuildScript of string

(*** Pre-processing of files that use `` *)
(*---------------------------------------------------------------------------
     Support for handling the preprocessing of files containing ``
 ---------------------------------------------------------------------------*)

(* does the file have an occurrence of `` *)
fun has_dq filename = let
  val istrm = TextIO.openIn filename
  fun loop() =
    case TextIO.input1 istrm of
      NONE => false
    | SOME #"`" => (case TextIO.input1 istrm of
                      NONE => false
                    | SOME #"`" => true
                    | _ => loop())
    | _ => loop()
in
  loop() before TextIO.closeIn istrm
end

fun variant str =  (* get an unused file name in the current directory *)
 if FileSys.access(str,[])
 then let fun vary i =
           let val s = str^Int.toString i
           in if FileSys.access(s,[])  then vary (i+1) else s
           end
      in vary 0
      end
 else str;


(*** Compilation of files *)

fun build_command c arg = let
  val include_flags = hmake_preincludes @ std_include_flags @
                      additional_includes
  val overlay_stringl =
    case actual_overlay of
      NONE => []
    | SOME s => [s]
(*  val include_flags = ["-I",SIGOBJ] @ additional_includes *)
  exception CompileFailed
  exception FileNotFound
in
  case c of
    MOSMLC =>
     let val file = fromFile arg
         val _ = FileSys.access(file, [FileSys.A_READ]) orelse
                  (print ("Wanted to compile "^file^", but it wasn't there\n");
                   raise FileNotFound)
         val _ = print ("Compiling "^file^"\n")
         open Process
         val res =
          if has_dq (normPath file) (* handle double-backquotes *)
          then let val clone = variant file
                   val _ = FileSys.rename {old=file, new=clone}
                   fun revert() = (FileSys.remove file handle _ => ();
                                   FileSys.rename{old=clone, new=file})
               in
                 if unquote_to clone file = Process.success
                 then let
                   val res =
                     compile debug ("-q"::(include_flags @ ["-c"] @
                                           overlay_stringl @ [file]))
                     handle e => (revert();
                                  print("Unable to compile: "^file^"\n");
                                  raise CompileFailed)
                 in revert(); res
                 end
                 else (revert(); raise CompileFailed)
               end
          else compile debug ("-q"::(include_flags@ ("-c"::(overlay_stringl @
                                                            [file]))))
     in
        res = success
     end
  | BuildScript s => let
      val scriptsml_file = SML (Script s)
      val scriptsml = fromFile scriptsml_file
      val script   = s^"Script"
      val scriptuo = script^".uo"
      val scriptui = script^".ui"
      open Process
      (* first thing to do is to create the Script.uo file *)
      val b = build_command MOSMLC scriptsml_file
      val _ = b orelse raise CompileFailed
      val _ = print ("Linking "^scriptuo^
                     " to produce theory-builder executable\n")
      val objectfiles =
        if allfast andalso not (member s fastfiles) orelse
           not allfast andalso member s fastfiles
        then ["fastbuild.uo", scriptuo]
        else if quit_on_failure then [scriptuo]
        else ["holmakebuild.uo", scriptuo]

    in
      if compile debug (include_flags @ ["-o", script] @ objectfiles) = success
      then let
        val script' = Systeml.mk_xable script
        val thysmlfile = s^"Theory.sml"
        val thysigfile = s^"Theory.sig"
        val _ =
          app (fn s => FileSys.remove s handle OS.SysErr _ => ())
          [thysmlfile, thysigfile]
        val res2    = Systeml.systeml [fullPath [FileSys.getDir(), script']]
        val _       = app FileSys.remove [script', scriptuo, scriptui]
      in
        (res2 = success) andalso
        (FileSys.access(thysmlfile, [FileSys.A_READ]) orelse
         (print ("Script file "^script'^" didn't produce "^thysmlfile^"; \n\
                 \  maybe need export_theory() at end of "^scriptsml^"\n");
         false)) andalso
        (FileSys.access(thysigfile, [FileSys.A_READ]) orelse
         (print ("Script file "^script'^" didn't produce "^thysigfile^"; \n\
                 \  maybe need export_theory() at end of "^scriptsml^"\n");
         false))
      end
      else (print ("Failed to build script file, "^script^"\n"); false)
    end handle CompileFailed => false
             | FileNotFound => false
end

fun do_a_build_command target pdep secondaries =
  case (extra_commands (fromFile target)) of
    SOME cs => run_extra_commands (fromFile target) cs = Process.success
  | NONE => let
    in
      case target of
         UO c           => build_command MOSMLC pdep
       | UI c           => build_command MOSMLC pdep
       | SML (Theory s) => build_command (BuildScript s) pdep
       | SIG (Theory s) => true (* because building our primary dependent,
                                   the Theory.sml file, will have built us too
                                *)
       | x => raise Fail ("Don't know how to build a "^fromFile x^"\n")
    end


exception CircularDependency
exception BuildFailure
exception NotFound

val up_to_date_cache:(File, bool)Polyhash.hash_table =
  Polyhash.mkPolyTable(50, NotFound)
fun cache_insert(f, b) = (Polyhash.insert up_to_date_cache (f, b); b)
fun make_up_to_date am_at_top ctxt target = let
  fun print s =
    if debug then (nspaces TextIO.print (length ctxt);
                   TextIO.print s)
    else ()
  val _ = print ("Working on target: "^fromFile target^"\n")
  val pdep = primary_dependent target
  val _ = List.all (fn d => d <> target) ctxt orelse
    (warn (fromFile target ^
           " seems to depend on itself - failing to build it\n");
     raise CircularDependency)
  val cached_result = Polyhash.peek up_to_date_cache target
in
  if isSome cached_result then
    valOf cached_result
  else
   if Path.dir (string_part target) <> "" then (* path outside of currDir *)
     (print (fromFile target ^" outside current directory; considered OK.\n");
      cache_insert (target, true))
    else
      if isSome pdep then let
        val pdep = valOf pdep
      in
        if make_up_to_date false (target::ctxt) pdep then let
          val secondaries = get_dependencies target
          val _ =
            (print ("Secondary dependencies for "^fromFile target^" are: ");
             print (print_list (map fromFile secondaries) ^ "\n"))
        in
          if (List.all (make_up_to_date false (target::ctxt)) secondaries) then
            if (List.exists
                (fn dep =>
                 (fromFile dep) forces_update_of (fromFile target))
                (pdep::secondaries)) then
              cache_insert (target, do_a_build_command target pdep secondaries)
            else
              cache_insert (target, true)
          else
            cache_insert (target, false)
        end
        else
          cache_insert (target, false)
      end
      else let
          val secondaries = get_dependencies target
          val _ =
            (print ("Secondary dependencies for "^fromFile target^" are: ");
             print (print_list (map fromFile secondaries) ^ "\n"))
          val tgt_str = fromFile target
        in
          if null secondaries then
            case extra_commands tgt_str of
              NONE => if FileSys.access(tgt_str, [FileSys.A_READ]) then
                        (if am_at_top then
                           warn ("*** Nothing to be done for `"^tgt_str^"'.\n")
                         else ();
                         cache_insert(target, true))
                      else
                        (warn ("*** No rule to make target `"^tgt_str^"'.\n");
                         cache_insert(target, false))
            | SOME cs => cache_insert(target, run_extra_commands tgt_str cs =
                                              Process.success)
          else if List.all (make_up_to_date false (target::ctxt))
                           secondaries
          then
            if List.exists
               (fn dep => (fromFile dep) forces_update_of (fromFile target))
               secondaries
            then
              case extra_commands (fromFile target) of
                (* NONE is impossible because for something to have
                   secondary dependencies, they will have come from
                   a Holmakefile or from automatic dependency analysis.
                   The latter is done for everything with primary dependents,
                   but in this branch, we have no primary dependent.
                   But, extra_commands will return SOME cl for every
                   rule.  cl may be the null list, but it will still be
                   there.

                   Recall the example of target "all", which can quite
                   reasonably have no commands, but just dependencies. *)
                NONE => raise Fail "Impossible situation #1"
              | SOME cs => cache_insert(target,
                                        run_extra_commands tgt_str cs =
                                        Process.success)
            else
              cache_insert(target, true)
          else
            cache_insert(target, false)
        end
end handle CircularDependency => cache_insert (target, false)
         | Fail s => raise Fail s
         | OS.SysErr(s, _) => raise Fail ("Operating system error: "^s)
         | HolDepFailed => cache_insert(target, false)
         | General.Io{function,name,cause = OS.SysErr(s,_)} =>
             raise Fail ("Got I/O exception for function "^function^
                         " with name "^name^" and cause "^s)
         | General.Io{function,name,...} =>
               raise Fail ("Got I/O exception for function "^function^
                         " with name "^name)
         | x => raise Fail "Got an unknown exception in make_up_to_date"

exception DirNotFound

(** Dealing with the command-line *)
fun do_target x = let
  fun read_files ds P action =
     case FileSys.readDir ds
      of NONE => FileSys.closeDir ds
       | SOME nextfile =>
           (if P nextfile then action nextfile else ();
            read_files ds P action)

  fun clean_action () = let
    val cdstream = FileSys.openDir "."
    fun to_delete f =
      case (toFile f) of
        UO _ => true
      | UI _ => true
      | SIG (Theory _) => true
      | SML (Theory _) => true
      | _ => false
    fun quiet_remove s = FileSys.remove s handle e => ()
  in
    read_files cdstream to_delete FileSys.remove;
    app quiet_remove extra_cleans;
    true
  end
  fun clean_deps() = let
    val depds = FileSys.openDir DEPDIR handle
      OS.SysErr _ => raise DirNotFound
  in
    read_files depds (fn _ => true)
    (fn s => FileSys.remove (fullPath [DEPDIR, s]));
    FileSys.rmDir DEPDIR;
    true
  end handle OS.SysErr (mesg, _) => let
             in
                print ("make cleanAll failed with message: "^mesg^"\n");
                false
             end
           | DirNotFound => true
in
  case x of
    "clean" => (let
    in
      print "Cleaning directory of object files\n";
      clean_action();
      true
    end handle _ => false)
  | "cleanDeps" => clean_deps()
  | "cleanAll" => clean_action() andalso clean_deps()
  | _ => if (not (member x dontmakes))
         then make_up_to_date true [] (toFile x)
         else true
end

fun generate_all_plausible_targets () = let
  val extra_targets = [toFile (#target(hd extra_rules))] handle Empty => []
  fun find_files ds P =
    case FileSys.readDir ds of
      NONE => []
    | SOME fname => if P fname then fname::find_files ds P
                               else find_files ds P
  val cds = FileSys.openDir "."
  fun ok_file f =
    case (toFile f) of
      SIG _ => true
    | SML _ => true
    | _ => false
  val src_files = find_files cds ok_file
  fun src_to_target (SIG (Script s)) = UO (Theory s)
    | src_to_target (SML (Script s)) = UO (Theory s)
    | src_to_target (SML s) = (UO s)
    | src_to_target (SIG s) = (UO s)
    | src_to_target _ = raise Fail "Can't happen"
  val initially = map (src_to_target o toFile) src_files @ extra_targets
  fun remove_sorted_dups [] = []
    | remove_sorted_dups [x] = [x]
    | remove_sorted_dups (x::y::z) = if x = y then remove_sorted_dups (y::z)
                                     else x :: remove_sorted_dups (y::z)
in
  remove_sorted_dups (Listsort.sort file_compare initially)
end


fun deal_with_targets list =
  case list of
    [] => let
      val targets = generate_all_plausible_targets ()
      val _ =
        if debug then
        print("Generated targets are: "^print_list (map fromFile targets)^"\n")
        else ()
    in
      alltrue (map (do_target o fromFile) targets)
    end
  | x =>  alltrue (map do_target x)


val _ =
  if show_usage then
    List.app print
    ["Holmake [targets]\n",
     "  special targets are:\n",
     "    clean                : remove all object code in directory\n",
     "    cleanDeps            : remove dependency information\n",
     "    cleanAll             : do all of above\n",
     "  additional command-line options are:\n",
     "    -I <file>            : include directory (can be repeated)\n",
     "    -d <file>            : ignore file (can be repeated)\n",
     "    -f <theory>          : toggles fast build (can be repeated)\n",
     "    --debug              : print debugging information\n",
     "    --fast               : files default to fast build; -f toggles\n",
     "    --help | -h          : show this message\n",
     "    --holdir <directory> : use specified directory as HOL root\n",
     "    --holmakefile <file> : use file as Holmakefile\n",
     "    --mosmldir directory : use specified directory as MoscowML root\n",
     "    --no_holmakefile     : don't use any Holmakefile\n",
     "    --no_overlay         : don't use an overlay file\n",
     "    --no_sigobj | -n     : don't use any HOL files from sigobj\n",
     "    --overlay <file>     : use given .ui file as overlay\n",
     "    --qof                : quit on tactic failure\n",
     "    --rebuild_deps | -r  : always rebuild dependency info files \n",
     "    --version | -v       : show version information\n"]
  else
    if show_version then
      print "Holmake version 3.0\n"
    else let
      open Process
      val result = deal_with_targets targets
        handle Fail s => (print ("Fail exception: "^s^"\n"); exit failure)
    in
      if result then exit success
      else die_with "Something went wrong somewhere."
    end


(** Local variable rubbish *)
(* local variables: *)
(* mode: sml *)
(* outline-regexp: " *(\\*\\*+" *)
(* end: *)
