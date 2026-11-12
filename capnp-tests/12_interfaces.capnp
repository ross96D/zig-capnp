@0x9c8f2d7f1a4b6e3d;

interface Calculator {
  add @0 (a :Int32, b :Int32) -> (sum :Value);
  reset @1 ();

  interface Value {
    eval @0 () -> (value: Int32);
  }
}

struct InterfaceHolder {
  calculator @0 :Calculator;
  calculators @1 :List(Calculator);
}
