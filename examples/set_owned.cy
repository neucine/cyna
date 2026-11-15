fn add_name(names: &Set<string>, name: string): void {
    names.add(name);
}

fn clear_local(names: Set<string>): i64 {
    var local = names;
    local.clear();
    return local.len() as i64;
}

fn main(): i32 {
    var names: Set<string> = set<string>();
    names.add("Ada");
    names.add("Ada");

    var copied = names.clone();
    var assigned = names;
    assigned.add("Ken");
    add_name(&assigned, "Lin");

    copied.add("Grace");

    const local_len = clear_local(assigned.clone());

    if assigned.contains("Ken") and assigned.contains("Lin") and copied.contains("Grace") and assigned.len() == 3 and copied.len() == 2 and local_len == 0 {
        return 42;
    }

    return 1;
}
