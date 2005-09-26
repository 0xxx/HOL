(*---------------------------------------------------------------------------
                An ML script for building HOL
 ---------------------------------------------------------------------------*)


(* utilities *)

(* ----------------------------------------------------------------------
    Magic to ensure that interruptions (SIGINTs) are actually seen by the
    linked executable as Interrupt exceptions
   ---------------------------------------------------------------------- *)

prim_val catch_interrupt : bool -> unit = 1 "sys_catch_break";
val _ = catch_interrupt true;


(* path manipulation functions *)
fun normPath s = Path.toString(Path.fromString s)
fun itstrings f [] = raise Fail "itstrings: empty list"
  | itstrings f [x] = x
  | itstrings f (h::t) = f h (itstrings f t);
fun fullPath slist = normPath
   (itstrings (fn chunk => fn path => Path.concat (chunk,path)) slist);

fun quote s = String.concat["\"", s, "\""];

(* message emission *)
fun die s =
    let open TextIO
    in
      output(stdErr, s ^ "\n");
      flushOut stdErr;
      Process.exit Process.failure
    end
fun warn s = let open TextIO in output(stdErr, s); flushOut stdErr end;


(* values from the Systeml structure, which is created at HOL configuration
   time *)
val OS = Systeml.OS;
val HOLDIR = Systeml.HOLDIR
val EXECUTABLE = Systeml.xable_string (fullPath [HOLDIR, "bin", "build"])
val DEPDIR = Systeml.DEPDIR
val GNUMAKE = Systeml.GNUMAKE
val DYNLIB = Systeml.DYNLIB

(* ----------------------------------------------------------------------
    Analysing the command-line
   ---------------------------------------------------------------------- *)

val cmdline = CommandLine.arguments()

(* use the experimental kernel? *)
val (use_expk, cmdline) =   let
  val (expks, rest) = List.partition (fn e => e = "-expk") cmdline
in
  (not (null expks), rest)
end

(* do self-tests? *)
val (do_selftests, cmdline) = let
  val (selftests, rest) = List.partition (fn e => e = "-selftest") cmdline
in
  (not (null selftests), rest)
end

(* use a non-standard build sequence? *)
val (bseq_fname, cmdline) = let
  fun analyse (acc as (fname, args')) num_seen args =
      case args of
        [] => (fname, List.rev args')
      | ["-seq"] => (warn "Trailing -seq command-line option ignored\n";
                     acc)
      | ("-seq"::fname::rest) =>
        (if num_seen = 1 then warn "Multiple -seq options; taking last one\n"
         else ();
         analyse (fname, args') (num_seen + 1) rest)
      | (x::rest) => analyse (fname, x::args') num_seen rest
in
  analyse (fullPath [HOLDIR, "tools", "build-sequence"], []) 0 cmdline
end


(*---------------------------------------------------------------------------
     Source directories.
 ---------------------------------------------------------------------------*)

val SRCDIRS0 = let
  fun read_file acc fstr =
      case TextIO.inputLine fstr of
        "" => List.rev acc
      | s => let
          val s = String.substring(s, 0, size s - 1) (* drop final \n char *)
          val ss = Substring.all s
          val ss = Substring.dropl Char.isSpace ss  (* drop leading w-space *)
          val (ss, _) = Substring.position "#" ss   (* drop trailing comment *)
          val s = Substring.string ss
        in
          if s = "" then read_file acc fstr
          else let
              val dirname = fullPath [HOLDIR, s]
              open FileSys
            in if access (dirname, [A_READ, A_EXEC]) then
                 if isDir dirname then read_file (s::acc) fstr
                 else (warn ("** File "^s^" from build sequence is not "^
                             "a directory -- skipping it\n");
                       read_file acc fstr)
               else (warn ("** File "^s^" from build sequence does not "^
                           "exist or is inacessible -- skipping it\n");
                     read_file acc fstr)
            end
        end
  val bseq_file =
      TextIO.openIn bseq_fname
      handle Io {cause, function, name} =>
             die ("Couldn't open build sequence file: "^bseq_fname)
in
  read_file [] bseq_file before TextIO.closeIn bseq_file
end

val SRCDIRS =
    map (fn s => fullPath [HOLDIR, s])
        ("src/portableML" :: "src/prekernel" ::
         (if use_expk then "src/experimental-kernel" else "src/0") ::
         SRCDIRS0)

val SIGOBJ = fullPath [HOLDIR, "sigobj"];
val HOLMAKE = fullPath [HOLDIR, "bin/Holmake"]

open Systeml;
val SYSTEML = Systeml.systeml

fun Holmake dir =
  if SYSTEML [HOLMAKE, "--qof"] = Process.success then
    if do_selftests andalso
       FileSys.access("selftest.exe", [FileSys.A_EXEC])
    then
      (print "Performing self-test...\n";
       if SYSTEML [dir ^ "/selftest.exe"] =
          Process.success
       then
         print "Self-test was successful\n"
       else
         die ("Selftest failed in directory "^dir))
    else
      ()
  else die ("Build failed in directory "^dir);


fun Gnumake dir =
  if SYSTEML [GNUMAKE] = Process.success then true
  else (warn ("Build failed in directory "^dir ^" ("^GNUMAKE^" failed).\n");
        false)

(* ----------------------------------------------------------------------
   Some useful file-system utility functions
   ---------------------------------------------------------------------- *)

(* map a function over the files in a directory *)
fun map_dir f dir =
  let val dstrm = FileSys.openDir dir
      fun loop () =
        case FileSys.readDir dstrm
         of NONE => []
          | SOME file => (dir,file)::loop()
      val files = loop()
      val _ = FileSys.closeDir dstrm
  in List.app f files
     handle OS.SysErr(s, erropt)
       => die ("OS error: "^s^" - "^
              (case erropt of SOME s' => OS.errorMsg s' | _ => ""))
       | otherexn => die ("map_dir: "^General.exnMessage otherexn)
  end;

fun rem_file f =
  FileSys.remove f
   handle _ => (warn ("Couldn't remove file "^f^"\n"); ());

fun copy file path =  (* Dead simple file copy *)
 let open TextIO
     val (istrm,ostrm) = (openIn file, openOut path)
     fun loop() =
       case input1 istrm
        of SOME ch => (output1(ostrm,ch) ; loop())
         | NONE    => (closeIn istrm; flushOut ostrm; closeOut ostrm)
  in loop()
  end;

fun bincopy file path =  (* Dead simple file copy - binary version *)
 let open BinIO
     val (istrm,ostrm) = (openIn file, openOut path)
     fun loop() =
       case input1 istrm
        of SOME ch => (output1(ostrm,ch) ; loop())
         | NONE    => (closeIn istrm; flushOut ostrm; closeOut ostrm)
  in loop()
  end;

(* create a symbolic link - Unix only *)
fun link b s1 s2 =
  let open Process
  in if SYSTEML ["ln", "-s", s1, s2] = success then ()
     else die ("Unable to link file "^quote s1^" to file "^quote s2^".")
  end

(* f is either bincopy or copy *)
fun update_copy f src dest = let
  val t0 = FileSys.modTime src
in
  f src dest;
  FileSys.setTime(dest, SOME t0)
end
fun cp b = if b then update_copy bincopy else update_copy copy

fun mv0 s1 s2 = let
  val s1' = normPath s1
  val s2' = normPath s2
in
  FileSys.rename{old=s1', new=s2'}
end

fun mv b = if b then mv0 else cp b

(* uploadfn is of type : bool -> string -> string -> unit
     the boolean is whether or not the arguments are binary files
     the strings are source and destination file-names, in that order
*)
fun transfer_file uploadfn targetdir (df as (dir,file)) = let
  fun transfer binaryp (dir,file1,file2) =
    uploadfn binaryp (fullPath [dir,file1]) (fullPath [targetdir,file2])
  fun idtransfer binaryp (dir,file) =
      case Path.base file of
        "selftest" => ()
      | _ => transfer binaryp (dir,file,file)
  fun digest_sig file =
      let val b = Path.base file
      in if (String.extract(b,String.size b -4,NONE) = "-sig"
             handle _ => false)
         then SOME (String.extract(b,0,SOME (String.size b - 4)))
         else NONE
      end
  fun augmentSRCFILES file = let
    open TextIO
    val ostrm = openAppend (Path.concat(SIGOBJ,"SRCFILES"))
  in
    output(ostrm,fullPath[dir,file]^"\n") ;
    closeOut ostrm
  end

in
  case Path.ext file of
    SOME"ui"     => idtransfer true df
  | SOME"uo"     => idtransfer true df
  | SOME"so"     => idtransfer true df   (* for dynlibs *)
  | SOME"xable"  => idtransfer true df   (* for executables *)
  | SOME"sig"    => (idtransfer false df; augmentSRCFILES (Path.base file))
  | SOME"sml"    => (case digest_sig file of
                       NONE => ()
                     | SOME file' =>
                       (transfer false (dir,file, file' ^".sig");
                        augmentSRCFILES file'))
  |    _         => ()
end;


(*---------------------------------------------------------------------------
           Compile a HOL directory in place. Some libraries,
           e.g., the robdd libraries, need special treatment because
           they come with external tools or C libraries.
 ---------------------------------------------------------------------------*)

fun build_dir dir = let
  val _ = FileSys.chDir dir
  val _ = print ("Working in directory "^dir^"\n")
in
  case #file(Path.splitDirFile dir) of
    "muddyC" => let
    in
      case OS of
        "winNT" => bincopy (fullPath [HOLDIR, "tools", "win-binaries",
                                      "muddy.so"])
                           (fullPath [HOLDIR, "sigobj", "muddy.so"])
      | other => if not (Gnumake dir) then
                   print(String.concat
                           ["\nmuddyLib has NOT been built!! ",
                            "(continuing anyway).\n\n"])
                 else ()
    end
  | "smv.2.4.3" => if not (Gnumake dir) then
                     print(String.concat
                             ["\nCompilation of SMV fails!!",
                              " temporal Lib has NOT been built!! ",
                              "(continuing anyway).\n\n"])
                   else ()
  | "HolCheck" => if not DYNLIB then
                    warn "*** Not building HolCheck as Dynlib, and hence \
                         \HolBddLib, not available\n"
                  else Holmake dir
  | _ => Holmake dir
end
handle OS.SysErr(s, erropt) =>
       die ("OS error: "^s^" - "^
            (case erropt of SOME s' => OS.errorMsg s' | _ => ""));


(*---------------------------------------------------------------------------
        Transport a compiled directory to another location. The
        symlink argument says whether this is via a symbolic link,
        or by copying. The ".uo", ".ui", ".so", ".xable" and ".sig"
        files are transported.
 ---------------------------------------------------------------------------*)

fun upload (src,target,symlink) =
  (print ("Uploading files to "^target^"\n");
   map_dir (transfer_file symlink target) src)
        handle OS.SysErr(s, erropt) =>
               die ("OS error: "^s^" - "^
                    (case erropt of SOME s' => OS.errorMsg s'
                                  | _ => ""));

(*---------------------------------------------------------------------------
    For each element in SRCDIRS, build it, then upload it to SIGOBJ.
    This allows us to have the build process only occur w.r.t. SIGOBJ
    (thus requiring only a single place to look for things).
 ---------------------------------------------------------------------------*)

fun buildDir symlink s = (build_dir s; upload(s,SIGOBJ,symlink));

fun build_src symlink = List.app (buildDir symlink) SRCDIRS

(*---------------------------------------------------------------------------*)
(* In clean_sigobj, we need to avoid removing the systeml stuff that will    *)
(* have been put into sigobj by the action of configure.sml                  *)
(*---------------------------------------------------------------------------*)

fun equal x y = (x=y);
fun mem x l = List.exists (equal x) l;

fun clean_sigobj() =
 let val _ = print ("Cleaning out "^SIGOBJ^"\n")
     val lowcase = String.map Char.toLower
     fun sigobj_rem_file s =
      let val f = Path.file s
          val n = lowcase (hd (String.fields (equal #".") f))
      in
         if mem n ["systeml", "cvs", "", "readme"]
          then ()
          else rem_file s
      end
     fun write_initial_srcfiles () =
      let open TextIO
          val outstr = openOut (fullPath [HOLDIR,"sigobj","SRCFILES"])
      in
        output(outstr, fullPath [HOLDIR, "tools", "Holmake", "Systeml"]);
        output(outstr, "\n");
        closeOut(outstr)
      end
 in
  map_dir (sigobj_rem_file o normPath o Path.concat) SIGOBJ;
  write_initial_srcfiles ();
  print (SIGOBJ ^ " cleaned\n")
 end;

fun build_adoc_files () = let
  val docdirs = let
    val instr = TextIO.openIn(fullPath [HOLDIR, "tools",
                                        "documentation-directories"])
    val wholefile = TextIO.inputAll instr before TextIO.closeIn instr
  in
    map normPath (String.tokens Char.isSpace wholefile)
  end handle _ => (print "Couldn't read documentation directories file\n";
                   [])
  val doc2txt = fullPath [HOLDIR, "help", "src", "Doc2Txt.exe"]
  fun make_adocs dir = let
    val fulldir = fullPath [HOLDIR, dir]
  in
    if SYSTEML [doc2txt, fulldir, fulldir] = Process.success then true
    else
      (print ("Generation of ASCII doc files failed in directory "^dir^"\n");
       false)
  end
in
  List.all make_adocs docdirs
end

fun build_help () =
 let val dir = Path.concat(Path.concat (HOLDIR,"help"),"src")
     val _ = FileSys.chDir dir
     val _ = build_dir dir (* builds the documentation tools called below *)
     val doc2html = fullPath [dir,"Doc2Html.exe"]
     val docpath  = fullPath [HOLDIR, "help", "Docfiles"]
     val htmlpath = fullPath [docpath, "HTML"]
     val _        = if (FileSys.isDir htmlpath handle _ => false) then ()
                    else (print ("Creating directory "^htmlpath^"\n");
                          FileSys.mkDir htmlpath)
     val cmd1     = [doc2html, docpath, htmlpath]
     val cmd2     = [fullPath [dir,"makebase.exe"]]
     val _ = print "Generating ASCII versions of Docfiles...\n"
     val _ = if build_adoc_files () then print "...ASCII Docfiles done\n"
             else ()
 in
   print "Generating HTML versions of Docfiles...\n"
 ;
   if SYSTEML cmd1  = Process.success then print "...HTML Docfiles done\n"
   else die "Couldn't make html versions of Docfiles"
 ;
   if (print "Building Help DB\n"; SYSTEML cmd2) = Process.success then ()
   else die "Couldn't make help database"
 end;

fun make_buildstamp () =
 let open Path TextIO
     val stamp_filename = concat(HOLDIR, concat("tools","build-stamp"))
     val stamp_stream = openOut stamp_filename
     val date_string = Date.toString (Date.fromTimeLocal (Time.now()))
 in
    output(stamp_stream, " (built "^date_string^")");
    closeOut stamp_stream
end

val logdir = Systeml.build_log_dir
val logfilename = Systeml.build_log_file
val hostname = if Systeml.isUnix then
                 case Mosml.run "hostname" [] "" of
                   Mosml.Success s => String.substring(s,0,size s - 1) ^ "-"
                                      (* substring to drop \n in output *)
                 | _ => ""
               else "" (* what to do under windows? *)

fun setup_logfile () = let
  open FileSys
  fun ensure_dir () =
      if access (logdir, []) then
        isDir logdir
      else (mkDir logdir; true)
in
  if ensure_dir() then
    if access (logfilename, []) then
      warn "Build log exists; new logging will concatenate onto this file\n"
    else let
        (* touch the file *)
        val outs = TextIO.openOut logfilename
      in
        TextIO.closeOut outs
      end
  else warn "Couldn't make or use build-logs directory\n"
end handle Io _ => warn "Couldn't set up build-logs\n"

fun finish_logging buildok = let
in
  if FileSys.access(logfilename, []) then let
      open Date
      val timestamp = fmt "%Y-%m-%dT%H%M" (fromTimeLocal (Time.now()))
      val newname0 = hostname^timestamp
      val newname = (if buildok then "" else "bad-") ^ newname0
    in
      FileSys.rename {old = logfilename, new = fullPath [logdir, newname]}
    end
  else ()
end handle Io _ => warn "Had problems making permanent record of build log\n"

val () = Process.atExit (fn () => finish_logging false)
        (* this will do nothing if finish_logging happened normally first;
           otherwise the log's bad version will be recorded *)

fun build_hol symlink = let
in
  clean_sigobj();
  setup_logfile();
  build_src symlink
    handle Interrupt => (finish_logging false; die "Interrupted");
  finish_logging true;
  make_buildstamp();
  build_help();
  print "\nHol built successfully.\n"
end


(*---------------------------------------------------------------------------
       Get rid of compiled code and dependency information.
 ---------------------------------------------------------------------------*)

local val lenScript = String.size "Script"
      val lenTheory_ext = String.size "Theory.sig"
in
fun suffixCheck s =
 let val len = String.size s
 in (("Script" = String.extract(s,len-lenScript,NONE)) orelse raise Subscript)
    handle Subscript
    =>  let val suffix = String.extract(s,len - lenTheory_ext, NONE)
        in (len > 10
            andalso ((suffix = "Theory.sig") orelse (suffix = "Theory.sml")))
           orelse raise Subscript
         end
        handle Subscript => false
  end
end;

infix called_in
fun (cmd called_in dir) = let
  val dir0 = FileSys.getDir()
  val _ = FileSys.chDir dir
in
  SYSTEML cmd before FileSys.chDir dir0
end

fun cleandir dir = ignore ([HOLMAKE, "clean"] called_in dir)
fun cleanAlldir dir = ignore ([HOLMAKE, "cleanAll"] called_in dir)

fun clean_dirs f =
    clean_sigobj() before
    (* clean both kernel directories, regardless of which was actually built,
       and the help src directory too *)
    List.app f (fullPath [HOLDIR, "help", "src"] ::
                fullPath [HOLDIR, "src", "0"] ::
                fullPath [HOLDIR, "src", "experimental-kernel"] ::
                SRCDIRS);

fun errmsg s = TextIO.output(TextIO.stdErr, s ^ "\n");
val help_mesg = "Usage: build\n\
                \   or: build -symlink\n\
                \   or: build -small\n\
                \   or: build -dir <fullpath>\n\
                \   or: build -dir <fullpath> -symlink\n\
                \   or: build -clean\n\
                \   or: build -cleanAll\n\
                \   or: build symlink\n\
                \   or: build small\n\
                \   or: build clean\n\
                \   or: build cleanAll\n\
                \   or: build help.\n\
                \Add -expk to build an experimental kernel.\n\
                \Add -selftest to do self-tests, where defined.\n\
                \Add -seq <fname> to use fname as build-sequence\n";

fun check_against s = let
  open Time
  val cfgtime = FileSys.modTime (fullPath [HOLDIR, s])
in
  if FileSys.modTime EXECUTABLE < cfgtime then
    (print ("WARNING! WARNING!\n");
     print ("  The build file is older than " ^ s ^ ";\n");
     print ("  this suggests you should reconfigure the system.\n");
     print ("  Press Ctl-C now to abort the build; <RETURN> to continue.\n");
     print ("WARNING! WARNING!\n");
     ignore (TextIO.inputLine TextIO.stdIn))
  else ()
end;

val _ = check_against "tools/smart-configure.sml"
val _ = check_against "tools/configure.sml"
val _ = check_against "tools/build.sml"
val _ = check_against "tools/Holmake/Systeml.sig"

fun symlink_check() =
    if OS = "winNT" then
      die "Sorry; symbolic linking isn't available under Windows NT"
    else link

val _ =
    case cmdline of
      []            => build_hol cp                (* no symbolic linking *)
    | ["-symlink"]  => build_hol (symlink_check()) (* w/ symbolic linking *)
    | ["-small"]    => build_hol mv                (* by renaming *)
    | ["-dir",path] => buildDir cp path
    | ["-dir",path,
       "-symlink"]  => buildDir (symlink_check()) path
    | ["-clean"]    => clean_dirs cleandir
    | ["-cleanAll"] => clean_dirs cleanAlldir
    | ["clean"]     => clean_dirs cleandir
    | ["cleanAll"]  => clean_dirs cleanAlldir
    | ["symlink"]   => build_hol (symlink_check())
    | ["small"]     => build_hol mv
    | ["help"]      => build_help()
    | otherwise     => errmsg help_mesg
