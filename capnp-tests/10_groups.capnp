@0x8e43d0e32fa0d2af;

struct WithGroup {
  point :group {
    x @0 :Int32;
    y @1 :Int32;
  }
}

struct WithUnionGroup {
  union {
    a :group {
      x @0 :Int32;
    }
    b @1 :Int32;
  }
}

const pointTest :WithGroup = (
  point = (x = 10, y = 20),
);

const unionTest :WithUnionGroup = (
  b = 7,
);
