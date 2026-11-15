pub enum WorkflowError: i32 {
    missing_primary = 0,
    missing_owner,
    invalid_summary,
}

pub struct Task {
    pub id: i32;
    pub owner: string;
    pub title: string;
    pub estimate: i32;
    pub blocked: bool;

    pub fn score(self: Task): i32 {
        const base = self.id + self.estimate + (self.title.len() as i32);
        if self.blocked {
            return base - 3;
        }
        return base;
    }
}
