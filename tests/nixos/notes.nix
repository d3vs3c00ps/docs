# Read code blocks from a note, as tests/lib/note.sh does in bash, so a NixOS test
# system is built from the note's own code instead of a copy that can drift.
#
#   block HEADING N    text of the Nth code block in the section whose heading contains
#                      HEADING. Blocks inside callouts are found too.
#   module HEADING N   the same block as a NixOS module. A note often shows a fragment
#                      (`services.x = { ... };`) or uses `pkgs` without a function
#                      header, so the text is wrapped as needed.
#
# A missing block is an error, so a test breaks loudly when the note changes under it.
{ lib, file }:
let
  lines = lib.splitString "\n" (builtins.readFile file);

  # Drop callout prefixes: "> ", ">> ".
  strip = l:
    let m = builtins.match "([ \t]*>[ \t]?)+(.*)" l;
    in if m == null then l else builtins.elemAt m 1;

  headingLevel = l:
    let m = builtins.match "(#+)[ \t].*" l;
    in if m == null then null else lib.stringLength (builtins.head m);

  # The fence that opens a block: its characters, or null.
  opening = l:
    let m = builtins.match "[ \t]*(```+|~~~+).*" l;
    in if m == null then null else builtins.head m;

  closes = fence: l:
    let
      t = lib.trim l;
      m = builtins.match "(```+|~~~+)" t;
    in m != null
      && lib.substring 0 1 t == lib.substring 0 1 fence
      && lib.stringLength t >= lib.stringLength fence;

  # Walk the lines once, collecting the code blocks of the chosen section.
  blocks = heading:
    let
      step = st: raw:
        let
          l = strip raw;
          level = headingLevel l;
        in
        if st.done then st
        else if st.fence != null then
          if closes st.fence l then
            st // { fence = null; cur = [ ]; } // lib.optionalAttrs st.armed { blocks = st.blocks ++ [ (lib.concatStringsSep "\n" st.cur) ]; }
          else if st.armed then st // { cur = st.cur ++ [ l ]; }
          else st
        else if level != null then
          if st.armed && level <= st.level then st // { done = true; }
          else if !st.armed && lib.hasInfix heading l then st // { armed = true; inherit level; }
          else st
        else if opening l != null then st // { fence = opening l; }
        else st;
      final = builtins.foldl' step { armed = false; done = false; level = 0; fence = null; cur = [ ]; blocks = [ ]; } lines;
    in
    if final.armed then final.blocks else throw "notes.nix: no heading contains '${heading}' in ${toString file}";

  block = heading: n:
    let bs = blocks heading;
    in if n >= 1 && n <= builtins.length bs then builtins.elemAt bs (n - 1)
    else throw "notes.nix: block '${heading}' #${toString n} not found in ${toString file} (the section has ${toString (builtins.length bs)})";

  # Comment lines do not decide the shape of the block.
  code = text: lib.trim (lib.concatStringsSep "\n" (builtins.filter (l: builtins.match "[ \t]*#.*" l == null) (lib.splitString "\n" text)));

  module = heading: n:
    let
      text = block heading n;
      c = code text;
      isFunction = builtins.match "[{][^}]*[}]:.*" (lib.replaceStrings [ "\n" ] [ " " ] c) != null;
      isAttrset = lib.hasPrefix "{" c;
      source =
        if isFunction then text
        else if isAttrset then "{ config, lib, pkgs, ... }:\n${text}"
        else "{ config, lib, pkgs, ... }: {\n${text}\n}";
    in
    import (builtins.toFile "note-block.nix" source);
in
{
  inherit block module;
}
