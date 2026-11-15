struct User {
    id: i32;
    addresses: List<string>;
}

fn main(): i32 {
    var user = User {
        id: 40,
        addresses: list_from<string>([:]string["home", "work"])
    };
    var handed_off = user;

    return handed_off.id + (handed_off.addresses.len() as i32);
}
