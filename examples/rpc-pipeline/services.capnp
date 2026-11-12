@0xa7e4c9d1b6f23850;

interface Factory {
  getGreeter @0 () -> (greeter :Greeter);
  getCalculator @1 () -> (calculator :Calculator);
  version @2 () -> (version :Text);
}

interface Greeter {
  hello @0 (name :Text) -> (message :Text);
  farewell @1 (name :Text) -> (message :Text);
}

interface Calculator {
  interface IntExpr {
    eval @0 () -> (value :Int32);
  }
  add @0 (a :IntExpr, b :IntExpr) -> (result :IntExpr);
  multiply @1 (a :IntExpr, b :IntExpr) -> (result :IntExpr);
}
