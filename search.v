module main

import time

const search_delay = 100 * time.millisecond

struct SearchRequest {
	generation int
	text       string
	cancel     &FetchCancellation = unsafe { nil }
}

fn (app &App) search_text() string {
	return if app.search_pending { app.search_request.text } else { app.search }
}

fn (mut app App) cancel_search() {
	if !isnil(app.search_request.cancel) { app.search_request.cancel.stop() }
	app.search_generation++
	app.search_pending = false
}

fn (mut app App) begin_search(text string) ?SearchRequest {
	if text == app.search_text() { return none }
	app.cancel_search()
	if text == app.search { return none }
	app.search_request = SearchRequest{
		generation: app.search_generation
		text:       text
		cancel:     &FetchCancellation{}
	}
	app.search_pending = true
	return app.search_request
}

fn (mut app App) apply_search_result(request SearchRequest) bool {
	if !app.search_pending || request.generation != app.search_generation || cancelled(request.cancel) {
		return false
	}
	app.search = request.text
	app.search_pending = false
	return true
}

fn search_in_background(request SearchRequest, results chan SearchRequest) {
	// The UI thread keeps accepting input while this timer waits.
	time.sleep(search_delay)
	if cancelled(request.cancel) { return }
	results <- request
	wake_ui()
}
