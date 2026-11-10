@0xd37a9815e2e653ff;

struct VoidFields {
    nothing @0 :Void;
    flag @1 :Bool;

    union {
        choice @2 :Void;
        value @3 :Int32;
    }
}
