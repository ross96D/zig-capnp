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
  add @0 (a :Int32, b :Int32) -> (result :Int32);
  multiply @1 (a :Int32, b :Int32) -> (result :Int32);
}
