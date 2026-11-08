@0x9277cd9557bda2c4;

annotation baz(*) :Int32;

$baz(1);

struct SomeStruct $baz(2) {
  myField @0 :Text = "default" $baz(3);
  myUnion :union $baz(4) {
    circle @1 :Float64;
    square @2 :Float64;
  }
}

annotation qux(struct, field) :Void;

struct MyStruct $qux {
  string @0 :Text $qux;
  number @1 :Int32 $qux;
}

annotation corge(file) :MyStruct;

$corge(string = "hello", number = 123);

struct Grault {
  value @0 :Int32 = 123;
}

annotation grault(file) :Grault;

$grault();
