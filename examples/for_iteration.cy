fn main(): i32 {
    var total: i32 = 0;

    const fixed: [3]i32 = [1, 2, 3];
    for value in fixed {
        total = total + value;
    }

    var xs: List<i32> = list_from<i32>([:]i32[4, 5]);
    for value in xs {
        total = total + value;
    }

    const view = xs.view();
    for value in view {
        total = total + value;
    }

    var seen: Set<i32> = set<i32>();
    seen.add(8);
    seen.add(8);
    seen.add(10);
    for value in seen {
        total = total + value;
    }

    if total == 42 {
        return 42;
    }

    return total;
}
