@0x9b1a2c3d4e5f6071;

struct Point {
  x @0 :Int32;
  y @1 :Int32;
  name @2 :Text = "origin";
}

struct Polyline {
  points @0 :List(Point);
}
