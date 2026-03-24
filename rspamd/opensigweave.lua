local rspamd_logger = require "rspamd_logger"
local rspamd_http = require "rspamd_http"
local ucl = require "ucl"
local lua_mime = require "lua_mime"

-- ==========================================
-- OPENSIGWEAVE CONFIGURATION
-- ==========================================
local ENGINE_API_KEY = "5dG46PIS76dsf68fanffggd870aejer7BW5T0NARsdfY8A967YERGxV"
local API_URL_BASE = "https://signature.hatsthings.com/api/signature/"

local html_splitters = {
    '<div class="gmail_quote"', '<div class=3D"gmail_quote"',
    '<div class="quote"', '<div class=3D"quote"',
    '<blockquote[^>]*type="cite"', '<blockquote[^>]*type=3D"cite"',
    '<div class="moz%-cite%-prefix">', '<div class=3D"moz%-cite%-prefix">',
    '<hr tabindex="%-%d+"', '<hr tabindex=3D"%-%d+"',
    '<div id="divRplyFwdMsg"', '<div id=3D"divRplyFwdMsg"',
    '<div style="border:none;border%-top:solid', '<div style=3D"border:none;border%-top:solid',
    '<div data%-marker="__QUOTED_TEXT__"', '<div data%-marker=3D"__QUOTED_TEXT__"',
    '<div class="yahoo_quoted"', '<div class=3D"yahoo_quoted"',
    '<blockquote id="isReplyContent"', '<blockquote id=3D"isReplyContent"',
    '<span id="OLK_SRC_BODY_SECTION"', '<span id=3D"OLK_SRC_BODY_SECTION"',
    '<div class="ox-[0-9a-f]+-quote"', '<div class=3D"ox-[0-9a-f]+-quote"'
}

local plain_splitters = {
    '\r?\nOn .- wrote:',
    '\r?\nAm .- schrieb .-*:',
    '\r?\nLe .- a écrit%s*:',
    '\r?\nEl .- escribió:',
    '\r?\n%-%-%- Original Message %-%-%-',
    '\r?\n_+?\r?\nFrom: .-\r?\nTo: ',
    '\r?\nFrom: .-\r?\nTo: ',
    '\r?\n".-" %S+@%S+',
    '\r?\n> '
}

local function inject_signature(task)
    local envfrom = task:get_from(1)
    local uname = task:get_user()
    if not envfrom or not uname then return false end

    local sender_email = envfrom[1].addr:lower()
    local is_reply = task:get_header_raw('in-reply-to') ~= nil or task:get_header_raw('references') ~= nil

    local function newline(task)
        local t = task:get_newlines_type()
        if t == 'cr' then return '\r'
        elseif t == 'lf' then return '\n'
        end
        return '\r\n'
    end

    local function http_callback(err, code, body, headers)
        if err or code ~= 200 then
            rspamd_logger.errx(task, "OpenSigWeave: API error (%s)", err or code)
            return
        end

        local parser = ucl.parser()
        local res, ucl_err = parser:parse_string(body)
        if not res then return end
        
        local data = parser:get_object()
        local html_sig = data.html
        
        -- Feature Toggles from API
        local inject_on_replies = data.inject_on_replies
        local trim_whitespace = data.trim_whitespace
        local strip_device_signatures = data.strip_device_signatures
        
        -- Defaults if API doesn't pass them
        if trim_whitespace == nil then trim_whitespace = true end
        if strip_device_signatures == nil then strip_device_signatures = false end

        if not html_sig or html_sig == "" then return end

        if is_reply and not inject_on_replies then
            rspamd_logger.errx(task, "OpenSigWeave: Reply detected, API flag is FALSE. Skipping.")
            return
        end

        local plain_sig = html_sig:gsub("<br.->", "\n"):gsub("<p.->", "\n"):gsub("<li.->", "\n- "):gsub("<[^>]+>", ""):gsub("&nbsp;", " ")

        local injected_inline = false
        local modified_raw_body = tostring(task:get_rawbody() or "")
        
        local qp_html_sig = html_sig:gsub("=", "=3D")
        local qp_plain_sig = plain_sig:gsub("=", "=3D")

        -- ==========================================================
        -- DEVICE SIGNATURE ASSASSIN
        -- ==========================================================
        if strip_device_signatures then
            -- Strips generic mobile footers in plain text and HTML
            modified_raw_body = modified_raw_body:gsub("\r?\n[Ss]ent from my [^\r\n<]+", "")
            modified_raw_body = modified_raw_body:gsub("\r?\n[Gg]et Outlook for [^\r\n<]+", "")
            modified_raw_body = modified_raw_body:gsub("<[bB][rR]%s*/?>[Ss]ent from my [^<]+", "")
            modified_raw_body = modified_raw_body:gsub("<[bB][rR]%s*/?>[Gg]et Outlook for [^<]+", "")
            modified_raw_body = modified_raw_body:gsub("<[dD][iI][vV][^>]*>[Ss]ent from my [^<]+</[dD][iI][vV]>", "")
            modified_raw_body = modified_raw_body:gsub("<[pP][^>]*>[Ss]ent from my [^<]+</[pP]>", "")
            modified_raw_body = modified_raw_body:gsub("<[dD][iI][vV][^>]*>[Gg]et Outlook for [^<]+</[dD][iI][vV]>", "")
            modified_raw_body = modified_raw_body:gsub("<[pP][^>]*>[Gg]et Outlook for [^<]+</[pP]>", "")
            rspamd_logger.errx(task, "OpenSigWeave: Device signature stripper executed.")
        end

        -- ==========================================================
        -- THE DIAMOND PEELERS
        -- ==========================================================
        local function clean_trailing_html(html)
            if not trim_whitespace then return html end
            html = html:gsub("=\r?\n", "")
            local prev
            repeat
                prev = html
                html = html:gsub("[%s\r\n]+$", "")
                html = html:gsub("=20$", "")
                html = html:gsub("=C2=A0$", "")
                html = html:gsub("\194\160$", "")
                html = html:gsub("=$", "")
                html = html:gsub("<[bB][rR]%s*/?>$", "")
                
                html = html:gsub("<[dD][iI][vV][^>]*>[%s=]*</[dD][iI][vV]>$", "")
                html = html:gsub("<[dD][iI][vV][^>]*>[%s=]*&nbsp;[%s=]*</[dD][iI][vV]>$", "")
                html = html:gsub("<[dD][iI][vV][^>]*>[%s=]*=C2=A0[%s=]*</[dD][iI][vV]>$", "")
                html = html:gsub("<[dD][iI][vV][^>]*>[%s=]*\194\160[%s=]*</[dD][iI][vV]>$", "")
                html = html:gsub("<[dD][iI][vV][^>]*>[%s=]*<[bB][rR]%s*/?>[%s=]*</[dD][iI][vV]>$", "")
                
                html = html:gsub("<[pP][^>]*>[%s=]*</[pP]>$", "")
                html = html:gsub("<[pP][^>]*>[%s=]*&nbsp;[%s=]*</[pP]>$", "")
                html = html:gsub("<[pP][^>]*>[%s=]*=C2=A0[%s=]*</[pP]>$", "")
                html = html:gsub("<[pP][^>]*>[%s=]*\194\160[%s=]*</[pP]>$", "")
                html = html:gsub("<[pP][^>]*>[%s=]*<[bB][rR]%s*/?>[%s=]*</[pP]>$", "")
            until html == prev
            return html
        end

        local function clean_trailing_plain(plain)
            if not trim_whitespace then return plain end
            plain = plain:gsub("=\r?\n", "")
            local prev
            repeat
                prev = plain
                plain = plain:gsub("[%s\r\n]+$", "")
                plain = plain:gsub("=20$", "")
                plain = plain:gsub("=C2=A0$", "")
                plain = plain:gsub("\194\160$", "")
                plain = plain:gsub("=$", "")
            until plain == prev
            return plain
        end

        -- REPLY SURGERY
        if is_reply then
            local function splice_body(body, splitters, signature, is_html)
                local best_s = nil
                for _, pattern in ipairs(splitters) do
                    local s, e = string.find(body, pattern)
                    if s then
                        if not best_s or s < best_s then best_s = s end
                    end
                end
                
                if best_s then
                    local before = string.sub(body, 1, best_s - 1)
                    local after = string.sub(body, best_s)
                    
                    if is_html then
                        before = clean_trailing_html(before)
                        local clean_sig = signature
                        if trim_whitespace then clean_sig = clean_trailing_html(signature):gsub("^[%s\r\n]+", "") end
                        
                        local html_spacer = '\n<div style="height:20px; line-height:20px; font-size:20px;">&nbsp;</div>\n'
                        return before .. html_spacer .. clean_sig .. html_spacer .. after, true
                    else
                        before = clean_trailing_plain(before)
                        local clean_sig = signature
                        if trim_whitespace then 
                            clean_sig = clean_trailing_plain(signature):gsub("^[%s\r\n]+", "")
                            after = after:gsub("^[%s\r\n=]+", "") 
                        end
                        return before .. "\r\n\r\n\r\n" .. clean_sig .. "\r\n\r\n\r\n" .. after, true
                    end
                end
                return body, false
            end

            local html_success = false
            modified_raw_body, html_success = splice_body(modified_raw_body, html_splitters, qp_html_sig, true)
            
            local plain_success = false
            modified_raw_body, plain_success = splice_body(modified_raw_body, plain_splitters, qp_plain_sig, false)

            injected_inline = html_success or plain_success
        end

        -- NEW EMAIL SURGERY
        if not injected_inline then
            local html_success = false
            local plain_success = false

            local last_body_s = nil
            for s in string.gmatch(modified_raw_body, "()</[bB][oO][dD][yY]>") do
                last_body_s = s
            end

            if last_body_s then
                local before = string.sub(modified_raw_body, 1, last_body_s - 1)
                local after = string.sub(modified_raw_body, last_body_s)
                before = clean_trailing_html(before)
                local clean_sig = qp_html_sig
                if trim_whitespace then clean_sig = clean_trailing_html(qp_html_sig):gsub("^[%s\r\n]+", "") end
                
                modified_raw_body = before .. "<br><br>\n" .. clean_sig .. "\n" .. after
                html_success = true
            end

            local ct_header = task:get_header_raw('Content-Type') or ""
            local boundary = ct_header:match('boundary="(.-)"') or ct_header:match('boundary=(%S+)')

            if boundary then
                local safe_b = boundary:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
                local pt_start, pt_content_start = string.find(modified_raw_body, "Content%-Type:%s*text/plain.-%r?\n%r?\n")
                
                if pt_content_start then
                    local b_s, b_e = string.find(modified_raw_body, "\r?\n%-%-" .. safe_b, pt_content_start)
                    if b_s then
                        local before = string.sub(modified_raw_body, 1, b_s - 1)
                        local after = string.sub(modified_raw_body, b_s)
                        before = clean_trailing_plain(before)
                        local clean_sig = qp_plain_sig
                        if trim_whitespace then clean_sig = clean_trailing_plain(qp_plain_sig):gsub("^[%s\r\n]+", "") end
                        
                        modified_raw_body = before .. "\r\n\r\n\r\n" .. clean_sig .. "\r\n" .. after
                        plain_success = true
                    end
                end
            else
                modified_raw_body = clean_trailing_plain(modified_raw_body)
                local clean_sig = qp_plain_sig
                if trim_whitespace then clean_sig = clean_trailing_plain(qp_plain_sig):gsub("^[%s\r\n]+", "") end
                
                modified_raw_body = modified_raw_body .. "\r\n\r\n\r\n" .. clean_sig .. "\r\n"
                plain_success = true
            end

            injected_inline = html_success or plain_success
        end

        -- ==========================================================
        -- MAILCOW ARRAY REBUILDER
        -- ==========================================================
        local out = {}
        local rewrite = {}
        local seen_cte = false
        local newline_s = newline(task)

        if not injected_inline then
            rewrite = lua_mime.add_text_footer(task, html_sig, plain_sig) or {}
            rspamd_logger.errx(task, "OpenSigWeave: All splices failed. Used Mailcow standard append.")
        end

        local function rewrite_ct_cb(name, hdr)
            if rewrite.need_rewrite_ct then
                if name:lower() == 'content-type' then
                    local boundary_part = rewrite.new_ct.boundary and string.format('; boundary="%s"', rewrite.new_ct.boundary) or ''
                    local nct = string.format('%s: %s/%s; charset=utf-8%s', 'Content-Type', rewrite.new_ct.type, rewrite.new_ct.subtype, boundary_part)
                    out[#out + 1] = nct
                    return
                elseif name:lower() == 'content-transfer-encoding' then
                    out[#out + 1] = string.format('%s: %s', 'Content-Transfer-Encoding', 'quoted-printable')
                    seen_cte = true
                    return
                end
            end
            out[#out + 1] = hdr.raw:gsub('\r?\n?$', '')
        end

        task:headers_foreach(rewrite_ct_cb, {full = true})
        if not seen_cte and rewrite.need_rewrite_ct then
            out[#out + 1] = string.format('%s: %s', 'Content-Transfer-Encoding', 'quoted-printable')
        end
        out[#out + 1] = "" 

        if injected_inline then
            out[#out + 1] = modified_raw_body
        elseif rewrite.out then
            for _,o in ipairs(rewrite.out) do
                out[#out + 1] = o
            end
        else
            out[#out + 1] = task:get_rawbody()
        end

        local out_parts = {}
        for _,o in ipairs(out) do
            if type(o) ~= 'table' then
                out_parts[#out_parts + 1] = o
                out_parts[#out_parts + 1] = newline_s
            else
                local removePrefix = "--\x0D\x0AContent-Type"
                if string.lower(string.sub(tostring(o[1]), 1, string.len(removePrefix))) == string.lower(removePrefix) then
                    o[1] = string.sub(tostring(o[1]), string.len("--\x0D\x0A") + 1)
                end
                out_parts[#out_parts + 1] = o[1]
                if o[2] then
                    out_parts[#out_parts + 1] = newline_s
                end
            end
        end

        task:set_message(out_parts)
    end

    rspamd_http.request({
        url = API_URL_BASE .. sender_email,
        task = task,
        method = 'GET',
        headers = { ['X-Engine-Key'] = ENGINE_API_KEY },
        callback = http_callback
    })
    return true
end

rspamd_config:register_symbol({
    name = 'OPENSIGWEAVE_INJECT',
    type = 'prefilter',
    callback = inject_signature,
    priority = 0
})
