enum AppStatus: i32 {
    ok = 0,
    empty_name,
    missing_score,
}

struct User {
    id: i32;
    name: string;

    fn name_len(self: User): i32 {
        return self.name.len() as i32;
    }
}

impl User: Clone {
    fn clone(self: &const User): User {
        return User {
            id: self.id,
            name: self.name.clone()
        };
    }
}

fn add_user(users: &List<User>, id: i32, name: string): void ! AppStatus {
    if name == "" {
        throw AppStatus.empty_name;
    }

    users.push(User {
        id: id,
        name: name
    });
    return;
}

fn score_users(users: List<User>): i32 ! AppStatus {
    var scores: Map<string, i32> = map<string, i32>();
    var names: Set<string> = set<string>();

    for user in users {
        scores[user.name] = user.id + user.name_len();
    }

    var score_names = scores.keys();
    for name in score_names {
        names.add(name);
    }

    if not names.contains("Ada") or not names.contains("Ken") {
        throw AppStatus.missing_score;
    }

    var total: i32 = 0;
    var score_values = scores.values();
    for score in score_values {
        total = total + score;
    }

    return total;
}

fn build(): i32 ! AppStatus {
    var users: List<User> = list<User>();
    try add_user(&users, 17, "Ada");
    try add_user(&users, 16, "Ken");

    const score = try score_users(users.clone());

    var owned = users;
    const last = owned.pop();

    if score == 39 and last.name == "Ken" and owned.len() == 1 {
        return 42;
    }

    return 1;
}

fn main(): i32 {
    const value = build() catch (status) {
        const ignored = status;
        return 1;
    };
    return value;
}
