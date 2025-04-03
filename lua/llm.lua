local M = {}
local Job = require("plenary.job")
local api = vim.api -- Make sure this exists!
local fn = vim.fn

-- Inside get_api_key
local function get_api_key(name)
	local key = os.getenv(name)
	-- More detailed print: Show start of key or nil
	if key then
		print("[dingllm_debug] Getting API key for: ", name, "- Found: YES - Starts with: ", string.sub(key, 1, 4))
	else
		print("[dingllm_debug] Getting API key for: ", name, "- Found: NO (nil)")
		vim.notify("API key environment variable not found: " .. name, vim.log.levels.WARN)
	end
	return key
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

function M.get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))

	if vim.fn.mode() == "V" then
		if srow > erow then
			return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
		else
			return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
		end
	end

	if vim.fn.mode() == "v" then
		if srow < erow or (srow == erow and scol <= ecol) then
			return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
		else
			return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
		end
	end

	if vim.fn.mode() == "\22" then
		local lines = {}
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		for i = srow, erow do
			table.insert(
				lines,
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
	end
end

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = {
		system = system_prompt,
		messages = { { role = "user", content = prompt } },
		model = opts.model,
		stream = true,
		max_tokens = 4096,
	}
	-- Add -sS for silent operation, show errors
	local args = { "-sS", "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "x-api-key: " .. api_key)
		table.insert(args, "-H")
		table.insert(args, "anthropic-version: 2023-06-01")
	end
	table.insert(args, url)
	return args
end

function M.make_ollama_spec_curl_args(opts, prompt)
	local url = opts.url or "http://localhost:11434/api/generate"
	local data = {
		model = opts.model or "llama3.2",
		prompt = prompt,
	}
	-- Add -sS for silent operation, show errors
	local args = {
		"-sS",
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data),
		url,
	}
	return args
end

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = {
		messages = { { role = "system", content = system_prompt }, { role = "user", content = prompt } },
		model = opts.model,
		temperature = 0.7,
		stream = true,
	}
	-- Add -sS for silent operation, show errors
	local args = { "-sS", "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args
end

function M.write_string_at_cursor(str)
	-- Print *before* scheduling
	print("[dingllm_debug] write_string_at_cursor called with string length:", #str)
	vim.schedule(function()
		-- Print *inside* the scheduled function
		print("[dingllm_debug] write_string_at_cursor - SCHEDULED function executing.")
		local current_window = vim.api.nvim_get_current_win()
		local cursor_position = vim.api.nvim_win_get_cursor(current_window)
		local row, col = cursor_position[1], cursor_position[2]

		local lines = vim.split(str, "\n")
		print("[dingllm_debug] write_string_at_cursor - Split into", #lines, "lines.")

		vim.cmd("undojoin")
		print("[dingllm_debug] write_string_at_cursor - About to call nvim_put.")
		vim.api.nvim_put(lines, "c", true, true)
		print("[dingllm_debug] write_string_at_cursor - nvim_put call finished.")

		local num_lines = #lines
		local last_line_length = #lines[num_lines]
		vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
		print("[dingllm_debug] write_string_at_cursor - Cursor set.")
	end)
end

local function get_prompt(opts)
	local replace = opts.replace
	local visual_lines = M.get_visual_selection()
	local prompt = ""

	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	return prompt
end

function M.handle_anthropic_spec_data(data_stream, event_state)
	if event_state == "content_block_delta" then
		local json = vim.json.decode(data_stream)
		if json.delta and json.delta.text then
			M.write_string_at_cursor(json.delta.text)
		end
	end
end

function M.handle_openai_spec_data(data_stream)
	if data_stream:match('"delta":') then
		local json = vim.json.decode(data_stream)
		if json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				M.write_string_at_cursor(content)
			end
		end
	end
end

function M.handle_ollama_spec_data(data_stream)
	local ok, json = pcall(vim.json.decode, data_stream)
	if ok and json and json.response then
		M.write_string_at_cursor(json.response)
	end
end

-- Inside make_gemini_spec_curl_args
-- Corrected function to handle Gemini API specifics
function M.make_gemini_spec_curl_args(opts, prompt, system_prompt)
	print("[dingllm_debug] Entering make_gemini_spec_curl_args")
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	if not api_key then
		vim.notify("Gemini API key not found for name: " .. (opts.api_key_name or "nil"), vim.log.levels.ERROR)
		return nil -- Cannot proceed without API key
	end

	-- Base URL for Gemini API V1 Beta
	local base_url = "https://generativelanguage.googleapis.com/v1beta/models/"
	local model = opts.model or "gemini-1.5-flash-latest" -- Default model
	local action = ":streamGenerateContent"
	-- API key as query parameter
	local key_param = "?key=" .. api_key
	-- *** ADD alt=sse for Server-Sent Events streaming format ***
	local sse_param = "&alt=sse"
	local full_url = base_url .. model .. action .. key_param .. sse_param

	print("[dingllm_debug] Gemini full_url with alt=sse:", full_url)

	-- Construct the payload according to Gemini API spec for streaming
	local contents = {}
	-- Note: Gemini's handling of system prompts can vary. Often it's part of the 'contents'
	-- or a separate 'system_instruction'. This example omits it for simplicity unless
	-- you specifically adapt the payload structure based on the model's documentation.
	if system_prompt and system_prompt ~= "" then
		print(
			"[dingllm_debug] System prompt provided for Gemini but might be ignored by current payload structure. Contents:",
			vim.inspect(contents)
		)
		-- Example structure if needed (uncomment/adapt):
		-- table.insert(contents, { role = "system", parts = { { text = system_prompt } } })
		-- OR use top-level system_instruction field if supported
	end

	-- *** Add print to check prompt before inserting ***
	print("[dingllm_debug] Prompt type before insert:", type(prompt))
	if type(prompt) == "string" then
		print("[dingllm_debug] Prompt value before insert (first 50 chars):", string.sub(prompt, 1, 50))
	else
		print("[dingllm_debug] Prompt value before insert is NOT a string:", prompt)
	end

	-- Add user prompt
	table.insert(contents, { role = "user", parts = { { text = prompt } } })

	local data = {
		contents = contents,
		generationConfig = {
			temperature = opts.temperature or 0.7,
			maxOutputTokens = opts.max_tokens or 2048, -- Adjust as needed
			-- topP, topK can also be added here
		},
		-- safetySettings = { ... } -- Optional: Add safety settings if needed
	}

	-- *** Add grounding tools if requested ***
	if opts.grounding == true then
		print("[dingllm_debug] Grounding with Google Search enabled.")
		data.tools = { { google_search = {} } }
	else
		print("[dingllm_debug] Grounding with Google Search disabled.")
	end

	-- Add -sS for silent operation, show errors
	local args = {
		"-sS",
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data),
	}
	table.insert(args, full_url)

	print("[dingllm_debug] Gemini curl args:", vim.inspect(args))
	print("[dingllm_debug] Gemini data:", vim.inspect(data))
	return args
end

-- Inside handle_gemini_spec_data
-- Revert to simpler version expecting JSON chunks after "data: " prefix
function M.handle_gemini_spec_data(data_chunk, _)
	print("[dingllm_debug] handle_gemini_spec_data received chunk:", data_chunk)
	local ok, decoded_obj = pcall(vim.json.decode, data_chunk)

	if ok and decoded_obj then
		print("[dingllm_debug] Gemini decoded JSON object:", vim.inspect(decoded_obj))

		-- *** Check if candidates field exists before trying to access it ***
		if
			decoded_obj.candidates
			and type(decoded_obj.candidates) == "table"
			and decoded_obj.candidates[1]
			and decoded_obj.candidates[1].content
			and decoded_obj.candidates[1].content.parts
			and type(decoded_obj.candidates[1].content.parts) == "table"
			and decoded_obj.candidates[1].content.parts[1]
			and decoded_obj.candidates[1].content.parts[1].text
			and type(decoded_obj.candidates[1].content.parts[1].text) == "string"
		then
			-- Candidates field exists and has the expected structure
			local text_chunk = decoded_obj.candidates[1].content.parts[1].text
			print("[dingllm_debug] Gemini extracted text chunk:", text_chunk)
			M.write_string_at_cursor(text_chunk)
		else
			-- Candidates field might be missing (e.g., metadata object) or structure is wrong.
			-- Only print a warning if the structure looks partially valid but text is missing.
			if decoded_obj.candidates then
				print(
					"[dingllm_warn] Gemini response object structure invalid or text path not found. Object:",
					vim.inspect(decoded_obj)
				)
			else
				-- No candidates field, likely metadata - ignore silently.
				print("[dingllm_debug] Gemini decoded object ignored (no candidates field, likely metadata).")
			end
		end
	else
		print("[dingllm_debug] Gemini failed to decode JSON chunk. Chunk content:", data_chunk)
	end
end

--
-- *** MODIFIED: Function for Full File Context + Selection Focus ***
function M.prompt_with_file_and_selection_context(opts, make_curl_args_fn, handle_data_fn)
	print("[dingllm_debug] Entering prompt_with_file_and_selection_context")
	opts = opts or {}

	-- 1. Get Visual Selection (Mandatory for this function)
	local selection_lines = M.get_visual_selection() -- Use the original function
	if not selection_lines then
		print("[dingllm_debug] No visual selection found.")
		vim.notify("Visual selection required for this prompt type.", vim.log.levels.WARN)
		return
	end
	-- Ensure it's a string
	local selection_text = ""
	if type(selection_lines) == "table" then
		selection_text = table.concat(selection_lines, "\\n")
	else -- Should already be string for char mode, but handle just in case
		selection_text = selection_lines
	end
	if selection_text == "" then
		vim.notify("Visual selection is empty.", vim.log.levels.WARN)
		return
	end
	print("[dingllm_debug] Selection text length:", #selection_text)

	-- If replacing, escape visual mode now
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)

	-- 2. Get Full File Content
	local current_buffer = vim.api.nvim_get_current_buf()
	local all_lines = vim.api.nvim_buf_get_lines(current_buffer, 0, -1, true)
	local full_file_content = table.concat(all_lines, "\\n")
	print("[dingllm_debug] Full file content length:", #full_file_content)

	-- 3. Construct the Custom Prompt
	local custom_prompt = string.format(
		[[
You should replace the code or text in the snippet, that you are sent, only following the comments. Do not talk at all. Output valid code only.
Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them.
Other comments should left alone. Do not output backticks

The user has provided the full content of their current file for context.
Focus your response primarily on the specific snippet they have highlighted, using the full file context only as needed to understand the snippet.

--- FULL FILE CONTEXT ---
%s
--- END FULL FILE CONTEXT ---

--- FOCUS SNIPPET ---
%s
--- END FOCUS SNIPPET ---

Based on the snippet (and the full context if relevant), provide your response:]],
		full_file_content,
		selection_text
	)
	print("[dingllm_debug] Custom prompt length:", #custom_prompt)

	-- Handle opts.replace and cursor positioning
	if opts.replace then
		local start_pos_vim = vim.fn.getpos("'<")
		local start_row = start_pos_vim[2]
		local start_col = start_pos_vim[3] - 1
		vim.api.nvim_command('normal! gv"_d')
		vim.api.nvim_win_set_cursor(0, { start_row, start_col })
	end

	-- 4. Add the prepared prompt to opts and call the invoker directly
	opts.prepared_prompt = custom_prompt -- Add the prompt to opts
	print("[dingllm_debug] Added prepared_prompt to opts. Calling invoke_llm_and_stream_into_editor.")

	-- Call invoker directly, passing original functions and modified opts
	M.invoke_llm_and_stream_into_editor(
		opts,
		make_curl_args_fn, -- Pass original make_args function
		handle_data_fn -- Pass original handle_data function
	)
end

-- Make sure this new function is included in the returned table M
-- (It should be automatically if defined as M.function_name = function...)

function M.prompt_ollama(opts)
	opts = opts or {}
	local prompt = get_prompt(opts)
	local args = M.make_ollama_spec_curl_args({
		url = opts.url or "http://localhost:11434/api/generate",
		model = opts.model or "llama2",
	}, prompt)

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	active_job = Job:new({
		command = "curl",
		args = args,
		on_stdout = function(_, line)
			M.handle_ollama_spec_data(line)
		end,
		on_stderr = function(_, err)
			print("Error:", err)
		end,
		on_exit = function()
			active_job = nil
		end,
	})

	active_job:start()

	vim.api.nvim_clear_autocmds({ group = group })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DING_LLM_Escape",
		callback = function()
			if active_job then
				active_job:shutdown()
				print("LLM streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User DING_LLM_Escape<CR>", { noremap = true, silent = true })
	return active_job
end

local group = vim.api.nvim_create_augroup("DING_LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
	print("[dingllm_debug] Entering invoke_llm_and_stream_into_editor")
	vim.api.nvim_clear_autocmds({ group = group })

	local final_args -- Variable to hold the final arguments for curl
	local curr_event_state = nil

	local prompt_to_use
	local system_prompt_to_use

	-- Check if a prompt was prepared by the caller
	if opts.prepared_prompt then
		print("[dingllm_debug] Using prepared_prompt from opts.")
		prompt_to_use = opts.prepared_prompt
		-- System prompt is generally ignored/handled differently with prepared prompts
		system_prompt_to_use = nil -- Set system prompt to nil when using prepared prompt
		print("[dingllm_debug] Prepared prompt length:", #prompt_to_use)
	else
		-- Standard call path, get prompt normally
		print("[dingllm_debug] No prepared_prompt found. Using get_prompt().")
		prompt_to_use = get_prompt(opts)
		system_prompt_to_use = opts.system_prompt
			or "You are a tsundere uwu anime. Yell at me for not setting my configuration for my llm plugin correctly" -- Default system prompt
		print(
			"[dingllm_debug] Standard call prompt length:",
			prompt_to_use and #prompt_to_use or "nil",
			"System prompt exists:",
			system_prompt_to_use ~= nil
		)
	end

	-- Call the provider-specific make_args function
	final_args = make_curl_args_fn(opts, prompt_to_use, system_prompt_to_use)

	if not final_args then
		vim.notify("Failed to create LLM request arguments.", vim.log.levels.ERROR)
		print("[dingllm_debug] make_curl_args_fn returned nil")
		return -- Stop if args creation failed
	end
	print("[dingllm_debug] FINAL curl args to be used:", vim.inspect(final_args))

	local function parse_and_call(line)
		-- Add check for nil line before processing
		if line == nil then
			print("[dingllm_debug] parse_and_call received nil line, skipping.")
			return
		end
		print("[dingllm_debug] parse_and_call received raw line:", line)

		-- Revert to original SSE parsing logic
		local event = line:match("^event: (.+)$")
		if event then
			print("[dingllm_debug] parse_and_call matched event:", event)
			curr_event_state = event
			return -- Event lines don't usually have data for the handler
		end

		local data_match = line:match("^data: (.+)$")
		if data_match then
			print("[dingllm_debug] parse_and_call matched data prefix, passing chunk to handler:", data_match)
			handle_data_fn(data_match, curr_event_state) -- Pass only the JSON part
		else
			print("[dingllm_debug] parse_and_call - Line ignored (no event/data prefix):", line)
		end
	end

	if active_job then
		print("[dingllm_debug] Shutting down pre-existing active job before starting new one.") -- Debug print
		active_job:shutdown()
		active_job = nil
	end

	-- *** Add print right before creating the job ***
	print("[dingllm_debug] About to create Job. final_args type:", type(final_args))
	if type(final_args) == "table" then
		print("[dingllm_debug] final_args content just before Job:new:", vim.inspect(final_args))
	else
		print("[dingllm_debug] final_args is NOT a table just before Job:new. Value:", final_args)
	end

	active_job = Job:new({
		command = "curl",
		args = final_args, -- Use the captured final_args
		on_stdout = vim.schedule_wrap(function(_, out) -- Wrap in schedule_wrap for safety
			print("[dingllm_debug] Job on_stdout received:", out) -- Print right inside callback
			parse_and_call(out)
		end),
		on_stderr = vim.schedule_wrap(function(_, err) -- Wrap in schedule_wrap
			if err and err ~= "" then
				print("[dingllm_stderr] Curl stderr:", err) -- Make output distinct
				vim.notify("LLM Job stderr: " .. err, vim.log.levels.WARN) -- Also notify
			end
		end),
		on_exit = vim.schedule_wrap(function(_, code) -- Wrap in schedule_wrap
			print("[dingllm_debug] Job exited with code:", code)
			-- Check buffer on exit
			if gemini_stream_buffer ~= "" then
				print(
					"[dingllm_warn] Job exited, but Gemini buffer was not empty or fully processed:",
					gemini_stream_buffer
				)
			end
			active_job = nil
			gemini_stream_buffer = "" -- Ensure buffer is cleared on exit
			-- Clean up the escape mapping ONLY when the job finishes naturally or is cancelled
			pcall(api.nvim_del_keymap, "n", "<Esc>")
			-- pcall(api.nvim_del_keymap, 'i', '<Esc>') -- Consider if needed
		end),
		stderr_buffered = false, -- Process stderr line-by-line
	})

	print("[dingllm_debug] Starting curl job...") -- Add print
	active_job:start()

	-- Setup autocmd AFTER starting the job
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DING_LLM_Escape",
		callback = function()
			M.cancel_llm_job() -- Call the new cancel function
		end,
	})

	-- Setup keymap AFTER starting the job and setting up autocmd
	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User DING_LLM_Escape<CR>", { noremap = true, silent = true })
	-- Consider if an insert mode escape is also needed:
	-- vim.api.nvim_set_keymap('i', '<Esc>', '<Cmd>doautocmd User DING_LLM_Escape<CR>', { noremap = true, silent = true })

	return active_job
end

-- New cancel function
function M.cancel_llm_job()
	print("[dingllm_debug] cancel_llm_job called.") -- Add print
	if active_job then
		print("[dingllm_debug] Shutting down active job.") -- Add print
		active_job:shutdown()
		print("LLM streaming cancelled.")
		active_job = nil
		gemini_stream_buffer = "" -- Clear Gemini stream buffer on cancel
		-- Clean up keymaps when cancelled
		pcall(api.nvim_del_keymap, "n", "<Esc>")
		-- pcall(api.nvim_del_keymap, 'i', '<Esc>') -- Match cleanup with setup
	else
		print("[dingllm_debug] No active job to cancel.") -- Add print
	end
end

return M
