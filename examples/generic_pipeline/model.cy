pub enum PipelineError: i32 {
    missing_seed = 0,
    empty_summary,
    invalid_total,
}

pub protocol Scored {
    fn points(self: Self): i32;
}

pub struct WorkItem {
    pub id: i32;
    pub owner: string;
    pub effort: i32;
    pub bonus: i32;
}

impl WorkItem: Scored {
    fn points(self: WorkItem): i32 {
        return self.id + self.effort + self.bonus + (self.owner.len() as i32);
    }
}
