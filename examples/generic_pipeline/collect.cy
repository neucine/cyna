import { WorkItem } from model;

pub fn seed_items(): [:]?WorkItem {
    var slots = [:]?WorkItem[
        WorkItem {
            id: 2,
            owner: "ops",
            effort: 5,
            bonus: 4
        },
        WorkItem {
            id: 3,
            owner: "qa",
            effort: 6,
            bonus: 2
        },
        none,
        WorkItem {
            id: 3,
            owner: "ops",
            effort: 4,
            bonus: 3
        },
    ];
    return slots;
}
