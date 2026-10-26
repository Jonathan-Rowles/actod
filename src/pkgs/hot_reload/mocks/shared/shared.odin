package hot_reload_shared

Counter_State :: struct {
	count: i32,
}

Bump :: struct {
	amount: i32,
	label:  string,
}

BUMP_LABEL :: "a label long enough that the message cannot travel inline and goes through the pool"
