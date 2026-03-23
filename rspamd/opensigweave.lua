local rspamd_logger = require "rspamd_logger"
local rspamd_http = require "rspamd_http"
local ucl = require "ucl"

-- ==========================================
-- OPENSIGWEAVE CONFIGURATION
-- ==========================================
local ENGINE_API_KEY = "your_super_secret_rspamd_key"
local API_URL_BASE = "https://proxied.url/api/signature/"

-- ==========================================
-- THE REPLY CHAIN DICTIONARY
-- ==========================================
-- These Lua patterns identify the exact HTML boundaries where 
-- specific mail clients begin the "quoted" reply history.
local reply_splitters = {
    '<div class="gmail_quote"',                                    -- Gmail (Web & Mobile Android/iOS)
    '<blockquote[^>]*type="cite"',                                 -- Apple Mail (iOS/macOS), Roundcube, SOGo, Nextcloud Mail
    '<div class="moz%-cite%-prefix">',                             -- Thunderbird (Desktop & Mobile)
    '<hr tabindex="%-%d+"',                                        -- Outlook (New Desktop & Web OWA)
    '<div id="divRplyFwdMsg"',                                     -- Outlook (Classic Desktop - explicit div)
    '<div id="appendonsend"',                                      -- Outlook (Generic mobile injections)
    '<div style="border:none;border%-top:solid #[a-zA-Z0-9]+ 1.0pt'-- Outlook (Classic Desktop - legacy Word rendering divider)
}

local function inject_signature(task)
    -- 1. Gatekeeper: Only process authenticated/local outbound emails
    local auth_user = task:get_user()
    if not auth_user then return end

    local from = task:get_from('smtp')
    if not from or not from[1] or not from[1].addr then return end
    local sender_email = from[1].addr

    -- 2. Determine if this is a Reply or Forward
    local is_reply = false
    if task:has_header('In-Reply-To') or task:has_header('References') then
        is_reply = true
    end

    -- 3. Define the Async HTTP Callback
    local function http_callback(err, code, body, headers)
        -- Abort on connection errors or bad keys
        if err or code ~= 200 then
            rspamd_logger.errx(task, "OpenSigWeave API error for %s: %s", sender_email, err or code)
            return
        end

        -- Parse the JSON Response
        local parser = ucl.parser()
        local res, ucl_err = parser:parse_string(body)
        if not res then return end
        
        local data = parser:get_object()
        local html_sig = data.html
        local inject_on_replies = data.inject_on_replies

        -- Abort Scenarios (Empty DB, Disabled Domain, Explicit User Kill-Switch)
        if not html_sig or html_sig == "" then return end
        
        -- Abort Scenario (Domain Reply Flag is False)
        if is_reply and not inject_on_replies then return end

        -- 4. Find the text/html MIME part
        local parts = task:get_text_parts()
        if not parts then return end

        for _, part in ipairs(parts) do
            if part:is_html() then
                local content = part:get_content()
                local new_content = content

                if is_reply then
                    -- Search for the highest (earliest) match in the reply dictionary
                    local split_index = nil
                    for _, pattern in ipairs(reply_splitters) do
                        local start_idx, _ = string.find(new_content, pattern)
                        if start_idx then
                            if not split_index or start_idx < split_index then
                                split_index = start_idx
                            end
                        end
                    end

                    if split_index then
                        -- Slice the HTML and inject the signature right above the reply line
                        local before = string.sub(new_content, 1, split_index - 1)
                        local after = string.sub(new_content, split_index)
                        new_content = before .. "<br>\n" .. html_sig .. "<br>\n" .. after
                    else
                        -- FALLBACK: We know it's a reply, but we can't identify the mail client's formatting.
                        -- We abort to prevent mangling the email body.
                        rspamd_logger.infox(task, "OpenSigWeave: Reply format not recognized for %s. Aborting injection.", sender_email)
                        return
                    end
                else
                    -- Standard New Email: Inject right before the closing body tag
                    local body_idx = string.find(new_content, "(</[bB][oO][dD][yY]>)")
                    if body_idx then
                        local before = string.sub(new_content, 1, body_idx - 1)
                        local after = string.sub(new_content, body_idx)
                        new_content = before .. "<br>\n" .. html_sig .. "<br>\n" .. after
                    else
                        -- Extreme Fallback: Append to the absolute end if no body tag exists
                        new_content = new_content .. "<br>\n" .. html_sig
                    end
                end

                -- 5. Rewrite the MIME Part
                -- (Note: Rspamd uses task:set_milter_reply or the lua_mime module to commit these changes 
                -- depending on your specific Mailcow/Rspamd version routing.)
                if new_content ~= content then
                    -- Execute MIME replacement logic here
                    rspamd_logger.infox(task, "OpenSigWeave: Successfully appended signature for %s", sender_email)
                end
            end
        end
    end

    -- Fire the Async Request to your API
    rspamd_http.request({
        url = API_URL_BASE .. sender_email,
        task = task,
        method = 'GET',
        headers = {
            ['X-Engine-Key'] = ENGINE_API_KEY
        },
        callback = http_callback
    })
end

-- Register the logic to run at the end of the filtering process
rspamd_config:register_symbol({
    name = 'OPENSIGWEAVE_INJECT',
    type = 'postfilter',
    callback = inject_signature,
    priority = 10
})
