---
title: The Nix language
description: Attribute sets, functions, laziness, let and with, the module system, and the syntax that trips everyone up
tags: [linux, nixos, nix, language, functional]
type: concept
status: complete
---

# The Nix language

Nix is a small, lazy, purely functional language whose only job is to describe how to
build things. It is not a general-purpose language and reads oddly at first — mostly
because of two unfamiliar choices: everything is an expression, and evaluation is
lazy.

```bash
nix repl
nix-instantiate --eval --expr '1 + 1'
```

`nix repl` is the right way to learn it. Evaluate fragments interactively rather than
guessing and rebuilding.

## Values

```nix
42                      # integer
3.14                    # float
"hello"                 # string
''
  multi-line
  string
''                      # indented string; leading indentation is stripped
true                    # boolean
null
./relative/path         # a path — a distinct type, not a string
[ 1 2 3 ]               # list — whitespace-separated, NO commas
{ a = 1; b = 2; }       # attribute set — semicolons, and a trailing one
```

> [!warning] Lists have no commas; attribute sets need trailing semicolons
> `[ 1, 2, 3 ]` is a list containing `1`, `,` … no. It is a syntax error, and the
> message will not say "you used commas". Likewise every attribute in a set ends with
> `;`, including the last.
>
> These two account for most early syntax errors.

## Attribute sets

The central data structure. NixOS configuration is one large attribute set.

```nix
let
  person = {
    name = "Alice";
    address = { city = "Paris"; country = "FR"; };
  };
in
  person.address.city          # "Paris"
```

Nested attributes can be written with dotted paths, which is why NixOS configuration
looks the way it does:

```nix
{
  services.nginx.enable = true;
  services.nginx.virtualHosts."example.com".root = "/var/www";
}

# exactly equivalent to
{
  services = {
    nginx = {
      enable = true;
      virtualHosts = { "example.com" = { root = "/var/www"; }; };
    };
  };
}
```

`rec` lets attributes refer to each other:

```nix
rec {
  version = "1.2.3";
  name = "myapp-${version}";
}
```

Default access, for attributes that may not exist:

```nix
person.nickname or "none"
```

## String interpolation

```nix
let name = "world";
in "hello ${name}"
```

Only `${}` interpolates — `$name` is a literal dollar sign. In an indented string,
escape a literal `${` as `''${`.

## Functions

Single-argument, always. Multiple arguments are done by currying:

```nix
x: x + 1                        # a function
(x: x + 1) 5                    # → 6

x: y: x + y                     # curried
```

In practice, functions take an attribute set with named parameters:

```nix
{ name, greeting ? "Hello" }: "${greeting}, ${name}!"
```

`?` gives a default. `...` accepts and ignores extra attributes — which is why every
NixOS module starts the way it does:

```nix
{ config, pkgs, lib, ... }:
```

That line is a **function** taking an attribute set, and returning the configuration.
Understanding that one line demystifies a lot.

## `let` and `with`

```nix
let
  x = 1;
  y = 2;
in
  x + y
```

```nix
with pkgs; [ vim git htop ]
# instead of [ pkgs.vim pkgs.git pkgs.htop ]
```

> [!warning] `with` hides where a name comes from
> It brings an entire set into scope, so you cannot see where a name came from. A
> typo is no longer caught when the file is parsed: it fails only when that value is
> used, as `undefined variable`, and without the `Did you mean ...?` hint that
> `pkgs.gti` gets. It is idiomatic in one specific place, `with pkgs; [ … ]` for
> package lists, and best avoided elsewhere.

> [!warning] Correction
> An earlier version said the error points at the `with` instead of the mistake. It
> does not: Nix points at the misspelled name. The real cost is the lost parse-time
> check and the lost hint.

## Laziness

Nothing is evaluated until needed:

```nix
let
  broken = throw "this would fail";
  fine = 42;
in
  fine            # → 42. `broken` is never evaluated
```

This is what makes the module system work: modules can refer to each other's options
freely without ordering constraints, because evaluation happens only when a value is
actually required.

It also means errors surface late and from surprising places, which is the main cost.

## Useful builtins and lib

```nix
builtins.length [ 1 2 3 ]                 # 3
builtins.toString 42
builtins.readFile ./file.txt
builtins.fromJSON ''{"a": 1}''
builtins.currentSystem                    # not in pure mode: flakes, nix eval

lib.mkIf condition { ... }                # conditional configuration
lib.mkDefault value                       # overridable default
lib.mkForce value                         # override everything else
lib.mkMerge [ a b ]
lib.optionals condition [ ... ]
lib.mapAttrs (name: value: ...) attrs
```

`lib.mkDefault` and `lib.mkForce` are what you reach for when a module sets something
you need to change:

```nix
services.nginx.package = lib.mkForce pkgs.nginxMainline;
```

## The module system

A NixOS module is a function returning an attribute set with three conventional keys.
`inherit (lib) ...` brings only the names it lists into scope, instead of `with lib;`:

```nix
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.myapp;
in {
  options.services.myapp = {
    enable = mkEnableOption "myapp";

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port to listen on.";
    };

    user = mkOption {
      type = types.str;
      default = "myapp";
      description = "User to run as.";
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
    };
    users.groups.${cfg.user} = {};

    systemd.services.myapp = {
      description = "myapp";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.myapp}/bin/myapp --port ${toString cfg.port}";
        User = cfg.user;
        Restart = "on-failure";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
```

| Key | Meaning |
| --- | --- |
| `options` | The typed settings this module declares |
| `config` | The configuration it produces when enabled |
| `imports` | Other modules to pull in |

> [!important] `config` is the merged result of everything, not just this file
> Reading `config.services.nginx.enable` gives the final value after every module has
> contributed — which is how a module can react to another being enabled. It is also
> why an accidental recursion between two modules produces the infamous "infinite
> recursion encountered" with no useful location.
>
> A common cause is a plain `if` around the whole `config`:
> `config = if cfg.enable then { ... } else { };`. To know which options the module
> sets, Nix must first read `cfg.enable`, which is the result it is still building.
> `lib.mkIf` exists to break that cycle: it lets the module system see the
> structure first and the condition later. The same applies to `imports`, which
> cannot depend on `config`.

> [!warning] Correction
> An earlier version said to break the cycle by reading the local `cfg` instead of
> `config`. That changes nothing: `cfg` is only a shorter name for
> `config.services.myapp`. Use `lib.mkIf` instead of `if`.

Types are checked, which is the module system's main benefit — `types.port` rejects
70000 at evaluation time rather than at runtime.

## Overriding packages

```nix
# Change a package's attributes
pkgs.hello.overrideAttrs (old: {
  version = "2.12";
  patches = [ ./my-patch.diff ];
})

# Change a function's arguments
pkgs.nginx.override { withDebug = true; }
```

System-wide, with an overlay:

```nix
nixpkgs.overlays = [
  (final: prev: {
    myapp = prev.myapp.overrideAttrs (old: { doCheck = false; });
  })
];
```

## Debugging

```bash
nix repl
nix-instantiate --eval --strict --expr '(import ./config.nix).services'
nix eval .#nixosConfigurations.web-01.config.services.nginx.enable
nixos-rebuild build --show-trace
```

`--show-trace` is essential — without it a type error deep in a module produces a
one-line message with no indication of where.

```nix
builtins.trace "value is ${toString x}" x    # printf debugging
lib.debug.traceVal someExpression
```

## Where to go next

- [[linux/distributions/nixos/derivations]] — what these expressions build
- [[linux/distributions/nixos/basics]] — applying a configuration
- [[linux/distributions/nixos/server]] — modules in practice

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
