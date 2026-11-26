import { equal } from .bytes;

struct ResourceRequirement {
    temporary_bytes: usize;
    alignment: usize;
}

struct ImplementationCost {
    model_id: u64;
    target_score: u64;
}

struct Layout {
    dimensions: List<usize>;
}

struct Candidate {
    step_index: usize;
    source_instruction: usize;
    implementation_id: List<u8>;
    implementation_version: u32;
    execution_class: i32;
    configuration: List<u8>;
    deterministic: bool;
    selected: bool;
    numerical_class: i32;
    layout_contract: i32;
    input_requirements: List<Layout>;
    output_properties: List<Layout>;
    resources: ResourceRequirement;
    cost: ImplementationCost;
}

struct Selection {
    step_index: usize;
    source_instruction: usize;
    implementation_id: List<u8>;
    implementation_version: u32;
    execution_class: i32;
    configuration: List<u8>;
    deterministic: bool;
    numerical_class: i32;
    layout_contract: i32;
    input_requirements: List<Layout>;
    output_properties: List<Layout>;
    resources: ResourceRequirement;
    cost: ImplementationCost;
}

fn candidate(configuration: u8): Candidate {
    var inputs: List<Layout> = list<Layout>();
    inputs.push(Layout { dimensions: list_from<usize>([:]usize [2, 3]) });
    var outputs: List<Layout> = list<Layout>();
    outputs.push(Layout { dimensions: list_from<usize>([:]usize [3, 2]) });
    return Candidate {
        step_index: 1,
        source_instruction: 7,
        implementation_id: list_from<u8>([:]u8 [1, 2]),
        implementation_version: 2,
        execution_class: 1,
        configuration: list_from<u8>([:]u8 [configuration]),
        deterministic: true,
        selected: true,
        numerical_class: 1,
        layout_contract: 1,
        input_requirements: inputs,
        output_properties: outputs,
        resources: ResourceRequirement { temporary_bytes: 64, alignment: 8 },
        cost: ImplementationCost { model_id: 1, target_score: 42 }
    };
}

fn selection(configuration: u8): Selection {
    var inputs: List<Layout> = list<Layout>();
    inputs.push(Layout { dimensions: list_from<usize>([:]usize [2, 3]) });
    var outputs: List<Layout> = list<Layout>();
    outputs.push(Layout { dimensions: list_from<usize>([:]usize [3, 2]) });
    return Selection {
        step_index: 1,
        source_instruction: 7,
        implementation_id: list_from<u8>([:]u8 [1, 2]),
        implementation_version: 2,
        execution_class: 1,
        configuration: list_from<u8>([:]u8 [configuration]),
        deterministic: true,
        numerical_class: 1,
        layout_contract: 1,
        input_requirements: inputs,
        output_properties: outputs,
        resources: ResourceRequirement { temporary_bytes: 64, alignment: 8 },
        cost: ImplementationCost { model_id: 1, target_score: 42 }
    };
}

fn has_duplicate_alternatives(alternatives: &const List<Candidate>): bool {
    var left: usize = 0;
    var duplicate = false;
    while left < alternatives.len() {
        var right = left + 1;
        while right < alternatives.len() {
            if not duplicate and
                alternatives[left].step_index == alternatives[right].step_index and
                alternatives[left].implementation_version == alternatives[right].implementation_version and
                equal(&alternatives[left].implementation_id, &alternatives[right].implementation_id) and
                equal(&alternatives[left].configuration, &alternatives[right].configuration) {
                duplicate = true;
            }
            right = right + 1;
        }
        left = left + 1;
    }
    return duplicate;
}

fn matches_selection(candidate_value: &const Candidate, selected: &const Selection): bool {
    return candidate_value.step_index == selected.step_index and
        candidate_value.source_instruction == selected.source_instruction and
        equal(&candidate_value.implementation_id, &selected.implementation_id) and
        candidate_value.implementation_version == selected.implementation_version and
        candidate_value.execution_class == selected.execution_class and
        equal(&candidate_value.configuration, &selected.configuration) and
        candidate_value.deterministic == selected.deterministic and
        candidate_value.numerical_class == selected.numerical_class and
        candidate_value.layout_contract == selected.layout_contract and
        candidate_value.input_requirements.len() == selected.input_requirements.len() and
        candidate_value.output_properties.len() == selected.output_properties.len() and
        candidate_value.resources.temporary_bytes == selected.resources.temporary_bytes and
        candidate_value.resources.alignment == selected.resources.alignment and
        candidate_value.cost.target_score == selected.cost.target_score;
}

fn validate(alternatives: &const List<Candidate>, selected: &const Selection): bool {
    if has_duplicate_alternatives(alternatives) {
        return false;
    }
    var index: usize = 0;
    while index < alternatives.len() {
        if alternatives[index].selected and
            matches_selection(&alternatives[index], selected) {
            return true;
        }
        index = index + 1;
    }
    return false;
}

fn main(): i32 {
    var alternatives: List<Candidate> = list<Candidate>();
    alternatives.push(candidate(3));
    alternatives.push(candidate(4));
    const selected = selection(3);
    const valid = validate(&alternatives, &selected);
    const wrong_selection = selection(5);
    const accepted_wrong_selection = validate(&alternatives, &wrong_selection);
    drop wrong_selection;
    var duplicates: List<Candidate> = list<Candidate>();
    duplicates.push(candidate(3));
    duplicates.push(candidate(3));
    const accepted_duplicates = validate(&duplicates, &selected);
    drop duplicates;
    drop selected;
    drop alternatives;
    if valid and not accepted_wrong_selection and not accepted_duplicates {
        return 42;
    }
    return 1;
}
