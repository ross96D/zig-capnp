@0x9c8f2d7f1a4b6e3d;

interface Calculator {
  add @0 (a :Int32, b :Int32) -> (sum :Int32);
  reset @1 ();
}

struct InterfaceHolder {
  calculator @0 :Calculator;
  calculators @1 :List(Calculator);
}
