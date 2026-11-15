type MaybeName = ?string;

fn maybe_name(pass: bool): MaybeName {
    if pass {
        return "Cyna";
    } else {
        return none;
    }
}

fn main(): i32 {
    const name: MaybeName = maybe_name(true);
    if name != none {
        if none == maybe_name(false) {
            return 42;
        } else {
            return 1;
        }
    } else {
        return 1;
    }
}
