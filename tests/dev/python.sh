#!/usr/bin/env bash
# note: dev/python.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/python
cd "$(mktemp -d)"
# b HEADING N [PRELUDE] [EPILOGUE]: run block N under HEADING in python3, with code before and after it.
b() { python3 -c "${3-}
$(note_block "$NOTE" "$1" "$2")
${4-}" 2>&1 || true; }
# j CMD...: CMD output on one line.
j() { "$@" | tr "\n" " " | sed "s/ $//"; }

section "Functions and classes"
check_output "greet returns the greeting" '^Hello, Alice!$' b Functions 1 '' 'print(message)'
check_output "the Car starts" '^The Toyota Camry is starting!$' b Classes 1 '' 'print(my_car.start_engine())'
check_output "early returns" '^Negative value, cannot process Zero value, nothing to do Processing value: 3$' \
  b 'Early returns' 1 '' 'print(process_value(-1), process_value(0), process_value(3))'
check_output "the validation form raises on a missing file" '^raised: SBOM file not found: nope.json$' \
  b 'Early returns' 2 'from pathlib import Path
class ValidationError(Exception): pass' 'try: validate_sbom("nope.json")
except ValidationError as e: print("raised:", e)'

section "Abstract classes and data classes"
check_output "Animal() is a TypeError, Dog() is fine" "TypeError: Can't instantiate abstract class Animal" b 'Abstract classes' 1
check_output "the dataclass repr" "^Person\(name='John', age=25, email='john@example.com'\)$" b 'Data classes' 1
check_output "frozen=True: read-only and hashable" '^FrozenInstanceError 1$' python3 -c '
from dataclasses import dataclass, FrozenInstanceError
@dataclass(frozen=True)
class P:
    x: int
p = P(1)
try: p.x = 2
except FrozenInstanceError as e: print(type(e).__name__, {p: 1}[P(1)])'

section "Method types"
check_output "give_raise" '^110$' b 'Method types' 1 '' 'e = Employee("a", 100); e.give_raise(10); print(e.salary)'
check_output "class methods: alternative constructor and class state" '^30000 ExampleCorp has 2 employees$' \
  b 'Method types' 2 '' 'Employee("a", 1); i = Employee.hire_intern("b"); print(i.salary, Employee.get_company_info())'
check_output "static method" '^15$' b 'Method types' 3 '' 'print(result)'

section "Dependency injection"
check_output "UserService gets its collaborators from the container" '^ok$' b 'Dependency injection' 1 '' '
user_service.create_user("bob")
class FakeDb:
    def connect(self): pass
class FakeMail:
    def __init__(self): self.sent = []
    def send(self, m): self.sent.append(m)
m = FakeMail(); UserService(FakeDb(), m).create_user("bob")
print("ok" if m.sent == ["Welcome bob!"] else m.sent)'

section "*args and **kwargs"
check_output "sum_all" '^6 100$' b '`*args`' 1 '' 'print(sum_all(1, 2, 3), sum_all(10, 20, 30, 40))'
check_output "display_info prints each pair" '^name: Alice age: 30 city: New York$' j b '`*args`' 2
check_output "process_data prints what the comments say" "^Source: file.csv Positional items: \(101, 102\) Metadata: \{'user': 'admin', 'status': 'processed'\}$" \
  j b '`*args`' 3

section "Generators"
gen=$(b Generators 1 '' 'try: next(counter)
except StopIteration: print("StopIteration")')
assert_eq "next() runs to each yield, then StopIteration" "Generator started!
1
2
3
Generator finished!
StopIteration" "$gen"
check_output "a for loop handles StopIteration" '^Generator started! 1 2 3 Generator finished!$' \
  j b Generators 2 "$(note_block "$NOTE" Generators 1 | sed -n '1,8p')"

section "Decorators"
check_output "the timer prints the real function name" "^Function 'slow_function' took 0\.0[0-9]{3} seconds\.$" b Decorators 1 '' 'slow_function(0.01)'
check_output "functools.wraps keeps __name__" '^slow_function$' b Decorators 1 '' 'print(slow_function.__name__)'
check_output "without wraps, the name is wrapper" '^wrapper$' \
  python3 -c "$(note_block "$NOTE" Decorators 1 | grep -v '@functools.wraps')
print(slow_function.__name__)"

section "Clean code conventions"
check_output "type hints and docstrings" '^5 Hello, Al! 6$' python3 -c "$(note_block "$NOTE" 'Type hints' 1)
$(note_block "$NOTE" Docstrings 1)
$(note_block "$NOTE" Docstrings 2)
print(add(2, 3), greet('Al'), multiply_numbers(2, 3))"
echo hello >file.txt
check_output "the context manager reads the file" '^hello$' b 'Context managers' 1 '' 'print(data, end="")'
check_output "logging: info, warning, error" '^INFO:__main__:This is an info message WARNING:__main__:This is a warning message ERROR:__main__:This is an error message$' \
  j b 'Logging, not' 1
check_output "tuples are immutable" "TypeError: 'tuple' object does not support item assignment" b 'Immutable data' 1 '' 'coordinates[0] = 1'

section "Enums"
check_output "plain constants are plain ints" '^True$' b 'Enums for fixed' 1 '' 'print(HTTPStatus.OK == 200)'
check_output "Enum members print, name and value as the comments say" "^HTTPStatus.OK OK 200$" \
  j b 'Enums for fixed' 2
check_output "an Enum member is not equal to its value" '^False True$' b 'Enums for fixed' 2 '' 'print(HTTPStatus.OK == 200, HTTPStatus.OK.value == 200)'
check_output "a missing member raises AttributeError" 'AttributeError' b 'Enums for fixed' 2 '' 'HTTPStatus.NOT_A_MEMBER'
check_output "IntEnum compares equal, like http.HTTPStatus" '^True True$' python3 -c '
import enum, http
class S(enum.IntEnum):
    OK = 200
print(S.OK == 200, http.HTTPStatus.OK == 200)'

section "try/except"
# Python 3.11+: a try that does not raise costs about nothing; raising is the expensive part.
check_output "Python is 3.11 or newer (zero-cost try)" '^True$' python3 -c 'import sys; print(sys.version_info >= (3, 11))'
check_output "a try that never raises is not slower than an if check" '^ok$' python3 -c '
import timeit
d = {"k": 1}
t_try = min(timeit.repeat("try:\n  d[\"k\"]\nexcept KeyError:\n  pass", globals=globals(), number=200000, repeat=5))
t_if = min(timeit.repeat("if \"k\" in d:\n  d[\"k\"]", globals=globals(), number=200000, repeat=5))
print("ok" if t_try < t_if * 1.2 else f"try={t_try} if={t_if}")'
check_output "raising is what costs" '^ok$' python3 -c '
import timeit
d = {}
t_raise = min(timeit.repeat("try:\n  d[\"k\"]\nexcept KeyError:\n  pass", globals=globals(), number=200000, repeat=5))
t_if = min(timeit.repeat("if \"k\" in d:\n  d[\"k\"]", globals=globals(), number=200000, repeat=5))
print("ok" if t_raise > t_if * 2 else f"raise={t_raise} if={t_if}")'

