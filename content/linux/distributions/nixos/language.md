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

## Operators

Each line gives the value `nix-instantiate --eval --strict` prints:

```nix
[ 1 2 ] ++ [ 3 ]                     # [ 1 2 3 ]
{ a = 1; b = 2; } // { b = 3; }      # { a = 1; b = 3; }
{ a.b = 1; } ? a.b                   # true
{ a = 1; }.b or 0                    # 0
"foo" + "bar"                        # "foobar"
2 + 3 * 4                            # 14
7 / 2                                # 3
7.0 / 2                              # 3.5
1 == 1.0                             # true
{ a = 1; } == { a = 1; }             # true
[ 1 2 ] < [ 1 3 ]                    # true
!true || true                        # true
false -> throw "never evaluated"     # true
```

`//` merges two sets, and the right side wins. `?` asks whether an attribute exists
and gives a boolean; `or` gives a fallback value. `->` is logical implication:
`a -> b` is `!a || b`.

From the tightest to the loosest. Operators on the same row have the same
precedence, and the [Nix manual](https://nix.dev/manual/nix/latest/language/operators)
numbers them 1 to 15:

| Operators | What they do | Associativity |
| --- | --- | --- |
| `s.a.b`, `s.a or x` | select an attribute, with a fallback | — |
| `f x` | call a function | left |
| `-x` | negate a number | — |
| `s ? a.b` | has attribute | — |
| `++` | join lists | right |
| `*` `/` | multiply, divide | left |
| `+` `-` | add, subtract; `+` also joins strings and paths | left |
| `!` | logical NOT | — |
| `//` | update a set | right |
| `<` `<=` `>` `>=` | compare | — |
| `==` `!=` | equal, not equal | — |
| `&&` | logical AND | left |
| `\|\|` | logical OR | left |
| `->` | logical implication | right |
| `\|>` `<\|` | pipe (experimental) | left, right |

`—` means the operator does not chain: `1 < 2 < 3` and `a == b == c` are syntax
errors. The right side of `&&`, `||` and `->` is evaluated only when it is needed,
which is why the `throw` above never runs. `//` evaluates both sides.

### Operator traps

- **`//` is shallow.** A nested set on the right replaces the one on the left; it is
  not merged. `{ a = { x = 1; }; } // { a = { y = 2; }; }` gives
  `{ a = { y = 2; }; }`. For a deep merge, use `lib.recursiveUpdate`. In NixOS
  modules, the module system merges for you, so this only bites in plain Nix code.
- **`/` needs spaces.** `6/3` is a relative path (`./6/3`), not 2. Write `6 / 3`.
  Division of two integers truncates toward zero: `7 / 2` is `3`, and `(0 - 7) / 2`
  is `-3`.
- **`-` needs spaces too.** A name may contain `-`, so `a-b` is one name, not
  `a - b`. This is why attributes such as `pkgs.xdg-utils` work.
- **A function call binds tighter than any operator, and a list element is not a
  call.** `map f xs ++ ys` is `(map f xs) ++ ys`. But in a list, `[ f 1 ]` is two
  elements, `f` and `1`: write `[ (f 1) ]`. A negative number in a list needs
  parentheses too: `[ 1 -2 ]` is a syntax error, `[ 1 (-2) ]` is not. And `f -1` is
  `f - 1`, a subtraction: write `f (-1)`.
- **`+` with paths copies files.** `./dir + "/file"` is still a path. Note the
  slash: `./. + "file"` glues the name to the folder, with no `/`. `"a" + ./file`
  is a string: the file is copied to the store and its store path is used, as in
  `"${./file}"`. Adding a number and a string is an error: use `toString`.
- **Functions are never equal.** `let f = x: x; in f == f` is `false`. Sets and lists
  are compared by value, element by element.
- **`|>` and `<|` are experimental.** They need
  `--extra-experimental-features pipe-operators`; without it, Nix stops with an
  error. `1 |> (x: x + 1) |> (x: x * 10)` is `20`.

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

### Partial application

Because each function takes one argument, giving only the first one returns a new
function that waits for the rest:

```nix
let
  add = x: y: x + y;
  inc = add 1;           # a function, still waiting for y
in
  inc 41                 # 42
```

One argument too many is an error: `add 1 2 3` gives `attempt to call something
which is not a function but an integer`.

### Argument sets

A function whose argument is written `{ … }` takes **one** attribute set and unpacks
it. The pattern decides what the set may contain:

| Pattern | Meaning |
| --- | --- |
| `{ a, b }:` | the set must have `a` and `b`, and nothing else |
| `{ a, b ? 2 }:` | `b` is optional, with the default `2` |
| `{ a, ... }:` | `a` is required; other attributes are accepted and ignored |
| `args@{ a, ... }:` | the same, and `args` is the whole set; `{ a, ... }@args:` also works |

```nix
let
  greet = { name, greeting ? "Hello", ... }@args:
    "${greeting}, ${name}! (${toString (builtins.length (builtins.attrNames args))} attributes)";
  name = "Alice";
in
  greet { inherit name; lang = "en"; }    # "Hello, Alice! (2 attributes)"
```

`inherit name;` in the call is short for `name = name;`. The count is 2, not 3:
`args` holds what the caller passed (`name` and `lang`), never the defaults.

Points that are easy to miss:

- **A default can use another argument.** `({ a, b ? a * 2 }: b) { a = 5; }` is `10`.
- **The set is checked when the function is called**, even for arguments the body
  never uses. Each mistake has its own message:

  | Call | Error |
  | --- | --- |
  | a required attribute is missing | `called without required argument 'name'` |
  | an extra attribute, and no `...` | `called with unexpected argument 'lang'` |
  | not a set at all | `expected a set but found a string` |

  The message names the function after its `let` binding (`function 'greet'`), or
  `anonymous lambda` when it has no name.
- **`x: x.name` is not the same as `{ name }: name`.** The first takes any value and
  fails only when it reads `.name`; the second checks the set at the call.
- **`builtins.functionArgs` lists the names a function expects**, with `true` for
  those that have a default:

  ```nix
  builtins.functionArgs ({ name, greeting ? "Hello", ... }: name)
  # { greeting = true; name = false; }
  ```

  This is how `callPackage` works. It reads the argument names of a package
  function, takes each one from `pkgs`, and lets you replace any of them:
  `pkgs.callPackage ./myapp.nix { }` passes `stdenv`, `fetchurl`, and the rest by
  name.
- **The `...` in a NixOS module is needed.** The module system passes more arguments
  than a module names, such as `options`. Without `...`, the module fails with
  `called with unexpected argument`.

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
