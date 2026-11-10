@0x8d4f6a2c1e9b7d3a;

struct Item {
  n @0 :Int32;
}

struct Box(T) {
  value @0 :T;
}

struct Holder {
  itemBox @0 :Box(Item);
  textBox @1 :Box(Text);
}
