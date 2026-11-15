struct Label {
    text: string;
}

fn main(): i32 {
    var label = Label {
        text: "Cyna"
    };
    drop label;
    return 42;
}
