@0xb3b6ae9aa3493ed3;

enum Color {
  red @0;
  green @1;
  blue @2;
}

struct Features {
  name @0 :Text;
  blob @1 :Data;
  color @2 :Color = green;
  colors @3 :List(Color);
  child @4 :Features;
  ptr @5 :AnyPointer;
  enabled @6 :Bool = true;
  ratio @7 :Float32 = 1.5;
  offset @8 :Int32 = -7;
}

const test :Features = (
  name = "hello",
  blob = 0x"6279746573",
  color = blue,
  colors = [red, green, blue],
  child = (name = "child"),
  enabled = false,
  ratio = 3.25,
  offset = 1234,
);
