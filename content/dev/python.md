---
title: Python
description: Functions, classes, dataclasses, decorators, generators and the clean-code conventions worth holding to
tags: [dev, python, programming]
type: reference
status: complete
---

# Python

Working notes on the parts of Python that come up repeatedly in tooling and service
code — the object model, the syntax that is easy to half-know, and the conventions
that keep a codebase readable.

## Functions

Reusable blocks of code that perform a specific task:

```python
def greet(name):
    return f"Hello, {name}!"

message = greet("Alice")  # "Hello, Alice!"
```

## Classes

Blueprints for creating objects — they define the properties and behaviours an
object will have:

```python
class Car:
    def __init__(self, make, model):
        self.make = make
        self.model = model

    def start_engine(self):
        return f"The {self.make} {self.model} is starting!"


my_car = Car("Toyota", "Camry")
```

## Early returns

Early returns keep functions flat and readable by avoiding deep nesting. Handle the
special cases immediately, then let the main logic sit unindented:

```python
def process_value(value):
    if value < 0:
        return "Negative value, cannot process"
    if value == 0:
        return "Zero value, nothing to do"
    return f"Processing value: {value}"
```

The same shape works for validation, raising instead of returning:

```python
def validate_sbom(sbom_file):
    sbom_path = Path(sbom_file)
    if not sbom_path.exists():
        raise ValidationError(f"SBOM file not found: {sbom_file}")
    ...
```

## Abstract classes

Incomplete blueprints that force subclasses to fill in the gaps. You cannot
instantiate them; they exist to enforce consistency:

```python
from abc import ABC, abstractmethod


class Animal(ABC):
    @abstractmethod
    def make_sound(self):
        ...


class Dog(Animal):
    def make_sound(self):
        return "Woof!"


dog = Dog()        # fine
animal = Animal()  # TypeError — abstract
```

## Data classes

A shortcut for classes that mostly hold data. Python generates `__init__`, `__repr__`
and `__eq__` for you:

```python
from dataclasses import dataclass


@dataclass
class Person:
    name: str
    age: int
    email: str


person = Person("John", 25, "john@example.com")
print(person)  # Person(name='John', age=25, email='john@example.com')
```

> [!tip] `frozen=True` gives you a hashable, immutable record
> `@dataclass(frozen=True)` makes instances read-only and usable as dictionary keys
> or set members. It is the right default for value objects — configuration,
> coordinates, anything that should not change after construction.

## Method types

**Instance methods** work on one object, through `self`:

```python
class Employee:
    def __init__(self, name, salary):
        self.name = name
        self.salary = salary

    def give_raise(self, amount):
        self.salary += amount
```

**Class methods** work on the class itself, through `cls`. They are most useful as
alternative constructors:

```python
class Employee:
    company_name = "ExampleCorp"
    employee_count = 0

    def __init__(self, name, salary):
        self.name = name
        self.salary = salary
        Employee.employee_count += 1

    @classmethod
    def get_company_info(cls):
        return f"{cls.company_name} has {cls.employee_count} employees"

    @classmethod
    def hire_intern(cls, name):
        return cls(name, 30000)
```

**Static methods** take neither `self` nor `cls` — plain functions grouped inside a
class for organisation:

```python
class MathUtils:
    @staticmethod
    def add(x, y):
        return x + y


result = MathUtils.add(5, 10)
```

| Kind | Receives | Answers |
| --- | --- | --- |
| Instance method | `self` | "What can *this* object do?" |
| Class method | `cls` | "What can the class do, or how does it build instances?" |
| Static method | nothing | "What utility belongs here conceptually?" |

Each serves a distinct purpose: abstract classes enforce structure, data classes cut
boilerplate, static methods organise utilities.

## Dependency injection

Rather than constructing dependencies inside a class, pass them in. The class stops
knowing how its collaborators are built, which is what makes it testable:

```python
class Database:
    def connect(self):
        return "Connected to database"


class EmailService:
    def send(self, message):
        return f"Sending: {message}"


class UserService:
    def __init__(self, database, email_service):
        self.db = database
        self.email = email_service

    def create_user(self, name):
        self.db.connect()
        self.email.send(f"Welcome {name}!")


class Container:
    def __init__(self):
        self._services = {}

    def register(self, name, service):
        self._services[name] = service

    def get(self, name):
        return self._services[name]


container = Container()
container.register("database", Database())
container.register("email", EmailService())

user_service = UserService(
    container.get("database"),
    container.get("email"),
)
```

The payoff is in tests: inject fakes and `UserService` needs no database at all.

## `*args` and `**kwargs`

`*args` collects extra positional arguments into a **tuple**:

```python
def sum_all(*args):
    return sum(args)


sum_all(1, 2, 3)        # 6
sum_all(10, 20, 30, 40) # 100
```

`**kwargs` collects keyword arguments into a **dictionary**:

```python
def display_info(**kwargs):
    for key, value in kwargs.items():
        print(f"{key}: {value}")


display_info(name="Alice", age=30, city="New York")
```

The names are convention; `*` and `**` are what matter. Combined:

```python
def process_data(source, *args, **kwargs):
    print(f"Source: {source}")
    print(f"Positional items: {args}")
    print(f"Metadata: {kwargs}")


process_data("file.csv", 101, 102, user="admin", status="processed")
# Source: file.csv
# Positional items: (101, 102)
# Metadata: {'user': 'admin', 'status': 'processed'}
```

## Generators and `yield`

Generators produce values one at a time instead of building a whole list, which
matters when the sequence is large or infinite.

Calling a function containing `yield` returns a generator object; nothing runs until
you iterate. Each iteration runs to the next `yield`, pauses, and resumes there next
time:

```python
def count_up_to(max_val):
    print("Generator started!")
    count = 1
    while count <= max_val:
        yield count
        count += 1
    print("Generator finished!")


counter = count_up_to(3)
print(next(counter))  # Generator started! then 1
print(next(counter))  # 2
print(next(counter))  # 3
# next(counter) now raises StopIteration
```

A `for` loop handles `StopIteration` for you:

```python
for number in count_up_to(3):
    print(number)
```

Use generators whenever you are streaming a large sequence — reading a multi-gigabyte
log line by line costs constant memory, while building the equivalent list does not.

## Decorators

A decorator extends a function's behaviour without editing it: a function that takes
a function, wraps it, and returns the replacement.

```python
import functools
import time


def timer_decorator(func):
    """Print how long a function takes to execute."""

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        start_time = time.perf_counter()
        result = func(*args, **kwargs)
        elapsed = time.perf_counter() - start_time
        print(f"Function '{func.__name__}' took {elapsed:.4f} seconds.")
        return result

    return wrapper


@timer_decorator
def slow_function(delay):
    time.sleep(delay)
    return "Done"
```

How it works:

1. `@timer_decorator` is shorthand for `slow_function = timer_decorator(slow_function)`.
2. The decorator receives the original function as `func`.
3. It defines `wrapper`, which runs code before and after calling `func`.
4. `*args` and `**kwargs` let the wrapper forward any signature.
5. It returns `wrapper`, which now stands in for the original.

> [!important] Always use `functools.wraps`
> Without it, the wrapper replaces the original's `__name__`, `__doc__` and
> signature. Every decorated function then reports itself as `wrapper`, which breaks
> introspection, documentation tooling and — most visibly — the very
> `func.__name__` this decorator prints.

> [!note] Prefer `time.perf_counter()` for timing
> `time.time()` measures wall-clock time and can jump backwards when the system clock
> is adjusted, for instance by NTP. `perf_counter()` is monotonic and higher
> resolution, which is what you want for measuring durations. See [[servers/chrony]].

Common uses: logging, authentication checks, caching (`functools.lru_cache`), retries
and timing.

## Clean code conventions

### Type hints

```python
def add(x: int, y: int) -> int:
    return x + y
```

They document intent and let `mypy` or `pyright` catch mistakes before runtime.

### Docstrings

```python
def greet(name: str) -> str:
    """Return a greeting for the given name."""
    return f"Hello, {name}!"
```

For anything with non-obvious arguments:

```python
def multiply_numbers(a: int, b: int) -> int:
    """
    Multiply two numbers and return the result.

    Args:
        a: The first number.
        b: The second number.

    Returns:
        The product of a and b.
    """
    return a * b
```

### Naming, per PEP 8

- Functions and variables — `snake_case`
- Classes — `CamelCase`
- Constants — `UPPER_CASE`

### Context managers

For files, sockets and locks, so cleanup happens even on an exception:

```python
with open("file.txt", encoding="utf-8") as f:
    data = f.read()
```

Always pass `encoding` explicitly — the default is platform-dependent and a
frequent source of bugs that only appear on someone else's machine.

### Avoid globals

They create hidden coupling and make code hard to test in isolation.

### Logging, not `print`

```python
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

logger.info("This is an info message")
logger.warning("This is a warning message")
logger.error("This is an error message")
```

Use a module-level logger named `__name__` rather than the root logger, so callers
can configure verbosity per module. See [[linux/logging/syslog]] for where the
output ends up.

### Immutable data

Prefer tuples and frozensets for anything that should not change:

```python
coordinates = (10, 20)
```

### Enums for fixed sets of constants

Grouping constants as class attributes works but leaves them as plain integers,
comparable to anything and vulnerable to typos:

```python
class HTTPStatus:
    OK = 200
    CREATED = 201
```

An `Enum` creates genuinely distinct members:

```python
from enum import Enum


class HTTPStatus(Enum):
    OK = 200
    CREATED = 201
    UNAUTHORIZED = 401
    FORBIDDEN = 403


print(HTTPStatus.OK)        # HTTPStatus.OK
print(HTTPStatus.OK.name)   # 'OK'
print(HTTPStatus.OK.value)  # 200
```

Why they are worth it:

- **Clarity** — `HTTPStatus.FORBIDDEN` says more than `403`.
- **Type safety** — a plain `Enum` member is not equal to its value, so
  `HTTPStatus.OK == 200` is `False`. Compare `HTTPStatus.OK.value == 200`.
- **Typos fail loudly** — accessing a member that does not exist raises
  `AttributeError` immediately.
- **Autocompletion** works properly.

> [!note] `IntEnum` when you do need integer comparison
> If members must behave as integers — serialising to JSON, comparing against
> library return values — use `enum.IntEnum` instead, where `HTTPStatus.OK == 200` is
> `True`. This is exactly what the standard library's own `http.HTTPStatus` does. Use
> plain `Enum` when you want the strictness, `IntEnum` when you want the
> interoperability.

## Vocabulary

| Term | Meaning |
| --- | --- |
| **Function** | A standalone block of code taking parameters and returning results |
| **Class** | A blueprint defining attributes and methods |
| **Method** | A function belonging to a class, able to access the object's state |
| **Object** | A specific instance created from a class |
| **Implementation** | The actual code that makes something work |

Classes contain methods, objects are created from classes, and functions stand alone.

## Assorted advice

- Use early returns to avoid deep nesting.
- Prefer list, dict and set comprehensions to `map` and `filter` — they read better
  and are usually faster.
- Keep functions small. If one does not fit on a screen, it is probably doing two
  things.

> [!note] `try/except` is not slow
> Avoiding `try/except` for speed does not match how CPython behaves:
>
> - **Entering a `try` block is essentially free.** Since the zero-cost exception
>   handling introduced in Python 3.11, a `try` that does not raise costs nothing at
>   runtime.
> - **Raising is what is expensive** — building the exception object and unwinding.
>
> So `try/except` is *faster* than checking first when the exception is rare, because
> you skip the check on every successful call. It is slower only when failure is
> common. This is why "easier to ask forgiveness than permission" is the idiomatic
> Python style, and why `d[key]` in a `try` beats `if key in d` for a lookup that
> nearly always succeeds. Choose on expected failure rate, not on a blanket rule.

## Where to go next

- [[dev/bdd-with-pytest]] — turning requirements into pytest tests
- [[dev/git-conventions]] — committing the result

<!-- uplink -->
Part of [[dev/index|Development]].
