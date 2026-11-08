@0x9064d9389017a737;
const pi :Float32 = 3.14159;

struct Defaults {
	int32 @0 :Int32 = 17;
	struct @1 :Defaults = (int32 = 15);
	float32 @2 :Float32 = .pi;
}

const test :Defaults = (int32 = 17);
