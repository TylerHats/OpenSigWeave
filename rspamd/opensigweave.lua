local rspamd_logger = require "rspamd_logger"
local rspamd_http = require "rspamd_http"
local ucl = require "ucl"
local rspamd_util = require "rspamd_util"

-- ==========================================
-- OPENSIGWEAVE CONFIGURATION
-- ==========================================
local ENGINE_API_KEY = "5dG46PIS76dsf68fanffggd870aejer7BW5T0NARsdfY8A967YERGxV"
local API_URL_BASE = "https://signature.hatsthings.com/api/signature/"

local html_splitters = {
    -- SOGo / Apple Mail Attribution Catchers
    '<br[^>]*>%s*<br[^>]*>%s*<br[^>]*>[^<]*On .- wrote:',
    '<br[^>]*>%s*<br[^>]*>[^<]*On .- wrote:',
    '<br[^>]*>[^<]*On .- wrote:',
    '<p[^>]*>&nbsp;</p>%s*On .- wrote:',
    
    -- Thunderbird Mobile Catchers
    '<hr[^>]*>%s*<b>From:</b>',
    '<div[^>]*>%s*<hr[^>]*>%s*<b>From:</b>',
    
    -- Standard Wrappers
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
    '\r?\n%-+ Original Message %-+', -- Catches any number of dashes (Thunderbird Mobile)
    '\r?\nOn .- wrote:',
    '\r?\nAm .- schrieb .-*:',
    '\r?\nLe .- a écrit%s*:',
    '\r?\nEl .- escribió:',
    '\r?\n_+?\r?\nFrom: .-\r?\nTo: ',
    '\r?\nFrom: .-\r?\nTo: ',
    '\r?\n".-" %S+@%S+',
    '\r?\n> '
}

local function inject_signature(task)
    local envfrom = task:get_from(1)
    local uname = task:get_user()
    if not envfrom or not uname then return false end

    local sender_email = tostring(envfrom[1].addr):lower()
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
        
        local inject_on_replies = data.inject_on_replies
        local trim_whitespace = data.trim_whitespace
        local strip_device_signatures = data.strip_device_signatures
        
        if trim_whitespace == nil then trim_whitespace = true end
        if strip_device_signatures == nil then strip_device_signatures = false end

        if not html_sig or html_sig == "" then return end

        if is_reply and not inject_on_replies then
            rspamd_logger.infox(task, "OpenSigWeave: Reply detected, API flag is FALSE. Skipping.")
            return
        end

        local plain_sig = html_sig:gsub("<br.->", "\n"):gsub("<p.->", "\n"):gsub("<li.->", "\n- "):gsub("<[^>]+>", ""):gsub("&nbsp;", " ")

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
                
                -- Aggressive gap removal for SOGo and Thunderbird
                html = html:gsub("<br[^>]*>[%s\r\n]*$", "")
                html = html:gsub("<[pP][^>]*>[%s\r\n]*</[pP]>$", "")
                html = html:gsub("<[pP][^>]*>[%s\r\n]*&nbsp;[%s\r\n]*</[pP]>$", "")
                html = html:gsub("<[pP][^>]*>[%s\r\n]*<br[^>]*>[%s\r\n]*</[pP]>$", "")
                html = html:gsub("<[dD][iI][vV][^>]*>[%s\r\n]*</[dD][iI][vV]>$", "")
                html = html:gsub("<[dD][iI][vV][^>]*>[%s\r\n]*<br[^>]*>[%s\r\n]*</[dD][iI][vV]>$", "")
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

        local function splice_body_logic(decoded_payload, splitters, signature, is_html)
            local spliced = decoded_payload
            local success = false

            if strip_device_signatures then
                spliced = spliced:gsub("\r?\n[Ss]ent from my [^\r\n<]+", "")
                spliced = spliced:gsub("\r?\n[Gg]et Outlook for [^\r\n<]+", "")
                spliced = spliced:gsub("<[bB][rR]%s*/?>[Ss]ent from my [^<]+", "")
                spliced = spliced:gsub("<[bB][rR]%s*/?>[Gg]et Outlook for [^<]+", "")
            end

            if is_reply then
                local best_s = nil
                for _, pattern in ipairs(splitters) do
                    local s, e = string.find(spliced, pattern)
                    if s and (not best_s or s < best_s) then best_s = s end
                end

                if best_s then
                    local before = string.sub(spliced, 1, best_s - 1)
                    local after = string.sub(spliced, best_s)

                    if is_html then
                        before = clean_trailing_html(before)
                        after = after:gsub("^([%s\r\n]*<[bB][rR]%s*/?>)+", "")
                        
                        local clean_sig = trim_whitespace and clean_trailing_html(signature):gsub("^[%s\r\n]+", "") or signature
                        
                        local html_spacer_top = '\n<br>\n<div style="display:block; clear:both;">\n'
                        local html_spacer_bottom = '\n</div>\n<br>\n'
                        
                        spliced = before .. html_spacer_top .. clean_sig .. html_spacer_bottom .. after
                    else
                        before = clean_trailing_plain(before)
                        local clean_sig = trim_whitespace and clean_trailing_plain(signature):gsub("^[%s\r\n]+", "") or signature
                        after = trim_whitespace and after:gsub("^[%s\r\n]+", "") or after
                        
                        spliced = before .. "\r\n\r\n" .. clean_sig .. "\r\n\r\n" .. after
                    end
                    success = true
                    rspamd_logger.infox(task, "OpenSigWeave: Successfully injected inline reply signature.")
                end
            end

            if not success then
                if is_html then
                    local last_body_s = nil
                    for s in string.gmatch(spliced, "()</[bB][oO][dD][yY]>") do last_body_s = s end

                    if last_body_s then
                        local before = string.sub(spliced, 1, last_body_s - 1)
                        local after = string.sub(spliced, last_body_s)
                        before = clean_trailing_html(before)
                        local clean_sig = trim_whitespace and clean_trailing_html(signature):gsub("^[%s\r\n]+", "") or signature
                        spliced = before .. "<br><br>\n" .. clean_sig .. "\n" .. after
                    else
                        local clean_sig = trim_whitespace and clean_trailing_html(signature):gsub("^[%s\r\n]+", "") or signature
                        spliced = clean_trailing_html(spliced) .. "<br><br>\n" .. clean_sig .. "\n"
                    end
                else
                    local clean_sig = trim_whitespace and clean_trailing_plain(signature):gsub("^[%s\r\n]+", "") or signature
                    spliced = clean_trailing_plain(spliced) .. "\r\n\r\n" .. clean_sig .. "\r\n"
                end
                success = true
                rspamd_logger.infox(task, "OpenSigWeave: Successfully appended new email signature to bottom.")
            end
            return spliced, success
        end

        local function process_mime_block(raw_body_str, target_type)
            local tgt_regex = ""
            for i = 1, #target_type do
                local c = target_type:sub(i, i)
                tgt_regex = tgt_regex .. "[" .. c:upper() .. c:lower() .. "]"
            end

            local ctype_pattern = "[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Tt][Yy][Pp][Ee]:%s*[Tt][Ee][Xx][Tt]/" .. tgt_regex .. ".-(\r?\n\r?\n)"
            local start_idx, header_end_idx = string.find(raw_body_str, ctype_pattern)
            
            if not start_idx then 
                return raw_body_str, false 
            end

            local part_headers = string.sub(raw_body_str, start_idx, header_end_idx)
            local end_idx = string.find(raw_body_str, "\r?\n%-%-", header_end_idx)
            if not end_idx then end_idx = #raw_body_str + 1 end
            
            local raw_payload = string.sub(raw_body_str, header_end_idx + 1, end_idx - 1)

            local encoding = "7bit"
            local cte_match = string.match(part_headers:lower(), "content%-transfer%-encoding:%s*([%w%-]+)")
            if cte_match then encoding = cte_match end

            local decoded = tostring(raw_payload)
            if encoding == "base64" then
                local dec = rspamd_util.decode_base64(raw_payload)
                if dec then decoded = tostring(dec) end
            elseif encoding == "quoted-printable" then
                local dec = rspamd_util.decode_qp(raw_payload)
                if dec then decoded = tostring(dec) end
            end

            local is_html = (target_type == "html")
            local spliced_payload, _ = splice_body_logic(decoded, is_html and html_splitters or plain_splitters, is_html and html_sig or plain_sig, is_html)

            local enc_payload = rspamd_util.encode_qp(spliced_payload, 76)
            local encoded_payload = enc_payload and tostring(enc_payload) or spliced_payload

            local stripped_headers = part_headers:gsub("\r?\n[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Tt][Rr][Aa][Nn][Ss][Ff][Ee][Rr]%-[Ee][Nn][Cc][Oo][Dd][Ii][Nn][Gg]:[^\r\n]*", "")
            stripped_headers = stripped_headers:gsub("\r?\n\r?\n$", "")
            local new_headers = stripped_headers .. "\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"

            local before_body = string.sub(raw_body_str, 1, start_idx - 1)
            local after_body = string.sub(raw_body_str, end_idx)

            return before_body .. new_headers .. encoded_payload .. after_body, true
        end

        local out = {}
        local newline_s = newline(task)
        
        local raw_body_data = task:get_rawbody()
        local raw_body = raw_body_data and tostring(raw_body_data) or ""
        
        local ct_raw = task:get_header_raw('Content-Type')
        local ct_header = ct_raw and tostring(ct_raw):lower() or ""
        
        local is_multipart = string.find(ct_header, "multipart") ~= nil
        local is_flat_plain = not is_multipart and (ct_header == "" or string.find(ct_header, "text/plain") ~= nil)

        if is_flat_plain then
            rspamd_logger.infox(task, "OpenSigWeave: Upgrading Flat text/plain to multipart/alternative.")
            
            local enc_raw = task:get_header_raw('Content-Transfer-Encoding')
            local encoding = (enc_raw and tostring(enc_raw) or "7bit"):lower()
            
            local decoded = tostring(raw_body)
            if encoding:find("base64") then
                local dec = rspamd_util.decode_base64(raw_body)
                if dec then decoded = tostring(dec) end
            elseif encoding:find("quoted%-printable") then
                local dec = rspamd_util.decode_qp(raw_body)
                if dec then decoded = tostring(dec) end
            end

            decoded = decoded:gsub("^[%s\r\n]+", ""):gsub("[%s\r\n]+$", "")

            local spliced_plain, _ = splice_body_logic(decoded, plain_splitters, plain_sig, false)

            local html_body = "<!DOCTYPE html>\n<html>\n<body>\n"
            local escaped_body = decoded:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\r?\n", "<br>\n")
            html_body = html_body .. escaped_body .. "\n</body>\n</html>"
            
            local spliced_html, _ = splice_body_logic(html_body, html_splitters, html_sig, true)

            local boundary = "=_OpenSigWeave_Alt_" .. rspamd_util.random_hex(12)
            
            local qp_plain = tostring(rspamd_util.encode_qp(spliced_plain, 76) or spliced_plain):gsub("[%s\r\n]+$", "")
            local qp_html = tostring(rspamd_util.encode_qp(spliced_html, 76) or spliced_html):gsub("[%s\r\n]+$", "")

            local new_multipart_body = "--" .. boundary .. "\r\n" ..
                "Content-Type: text/plain; charset=utf-8\r\n" ..
                "Content-Transfer-Encoding: quoted-printable\r\n\r\n" ..
                qp_plain .. "\r\n" ..
                "--" .. boundary .. "\r\n" ..
                "Content-Type: text/html; charset=utf-8\r\n" ..
                "Content-Transfer-Encoding: quoted-printable\r\n\r\n" ..
                qp_html .. "\r\n" ..
                "--" .. boundary .. "--\r\n\r\n"

            -- MILTER FIX: Explicitly force Postfix to rewrite the routing headers
            task:modify_header('Content-Type', 'multipart/alternative; boundary="' .. boundary .. '"')
            task:modify_header('Content-Transfer-Encoding', '7bit')

            local ct_replaced = false
            local function rewrite_flat_ct(name, hdr)
                local lname = string.lower(name)
                if lname == 'content-type' then
                    if not ct_replaced then
                        out[#out + 1] = 'Content-Type: multipart/alternative; boundary="' .. boundary .. '"'
                        ct_replaced = true
                    end
                    return
                elseif lname == 'content-transfer-encoding' then
                    out[#out + 1] = 'Content-Transfer-Encoding: 7bit'
                    return 
                end
                out[#out + 1] = hdr.raw:gsub('\r?\n?$', '')
            end

            task:headers_foreach(rewrite_flat_ct, {full = true})
            
            if not ct_replaced then
                out[#out + 1] = 'Content-Type: multipart/alternative; boundary="' .. boundary .. '"'
            end
            
            out[#out + 1] = ""
            out[#out + 1] = new_multipart_body
            
        else
            local html_success, plain_success = false, false
            raw_body, html_success = process_mime_block(raw_body, "html")
            raw_body, plain_success = process_mime_block(raw_body, "plain")
            
            local function passthrough_headers(name, hdr)
                out[#out + 1] = hdr.raw:gsub('\r?\n?$', '')
            end
            
            task:headers_foreach(passthrough_headers, {full = true})
            out[#out + 1] = ""
            out[#out + 1] = raw_body
        end

        local out_parts = {}
        for _, str in ipairs(out) do
            out_parts[#out_parts + 1] = str
            out_parts[#out_parts + 1] = newline_s
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
    name = 'OPENSIGWEave_INJECT',
    type = 'prefilter',
    callback = inject_signature,
    priority = 0
})
