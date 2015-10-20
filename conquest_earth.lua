-- Copyright (c) 2015 Michael Ehrenreich

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.


local vs = require("vstruct")
vs.cache = true

local lfs = require("lfs")

-- FIXME: Implement RNC2 decompression... Can't be bothered TBH...
--local rnc2 = require("rnc2")

local idstring = "XCELZLIB"
local b_extract = true

function tprint(tbl, indent)
  if not indent then indent = 0 end
  for k, v in pairs(tbl) do
    formatting = string.rep("  ", indent) .. k .. ": "
    if type(v) == "table" then
      print(formatting)
      tprint(v, indent+1)
    else
      print(formatting .. tostring(v))
    end
  end
end

function mergeTables(t1, t2)
    for k,v in pairs(t2) do
        t1[k] = v
    end
end

function warn(msg)
    io.stderr:write("WARNING: " .. tostring(msg) .. "\n")
end

function b2f(str)
    return (string.gsub(str, "\\", "/"))
end


function check_idstring(f)
    f:seek("end", -8)
    local ids = f:read(8)
    if ids ~= idstring then
        error("Not a valid file: " .. tostring(ids))
    end
end

function read_info(f)
    local size = f:seek("end")
    if size < 20 then
        error("File too small to contain footer")
    end
    
    f:seek("end", -20)
    return vs.read("version:u4 fat_offset:u4 fat_length:u4", f)
end

function fat_seek(f, info, offset)
    f:seek("set", info.fat_offset + offset)
end

function read_dirheader(f, info)
    -- content_offset is the offset directly after the dirheader == offset of the first entry
    local header = vs.read("entry_offset:u4 entry_count:u4 name:z", f)
    fat_seek(f, info, header.entry_offset)
    return header
end

function read_entry(f, info)
    -- endoffset for directories is offset of own dirheader
    local entry = vs.read("data_offset:u4 length:u4 data_length:u4 endoffset_or_unpacked_length:u4 nextoffset:u4 is_compressed:u1 name_len:u4 name:z", f)
    fat_seek(f, info, entry.nextoffset)
    return entry
end

function postprocess_entry(entry)
    if entry.postprocess_step == 1 then
        if entry.data_length == 0xFFFFFFFF then
            entry.is_dir = true
            entry.data_offset = nil
            entry.data_length = nil
            entry.endoffset = entry.endoffset_or_unpacked_length
            entry.is_compressed = nil
        else
            entry.is_dir = false
            entry.is_compressed = entry.is_compressed ~= 0

            if entry.is_compressed then
                entry.unpacked_length = entry.endoffset_or_unpacked_length
            else
                if entry.endoffset_or_unpacked_length ~= entry.data_length then
                    warn("unpacked_length: " .. tostring(entry.endoffset_or_unpacked_length) .. " ~= data_length: " .. tostring(entry.data_length) .. " on entry " .. tostring(entry.name))
                end
            end
        end

        entry.endoffset_or_unpacked_length = nil
        entry.length = nil
        entry.name_len = nil

        entry.postprocess_step = 2
    elseif entry.postprocess_step == 2 then
        entry.nextoffset = nil
        entry.endoffset = nil

        entry.postprocess_step = nil
    end
end

function read_directory(f, info)
    local header = read_dirheader(f, info)
    local entries = {}

    local i
    for i=1, header.entry_count do
        local entry = read_entry(f, info)
        entry.postprocess_step = 1
        postprocess_entry(entry)

        -- FIXME: Directory is *usually* called '..'; if it's named differently,
        --        we'll get a stack overflow.
        if entry.is_dir and entry.name ~= '..' then
            fat_seek(f, info, entry.endoffset)
            entry.entries = read_directory(f, info)
        end

        entries[i] = entry

        fat_seek(f, info, entry.nextoffset)
        
        postprocess_entry(entry)
    end

    return entries
end

function read_fat(f, info)
    fat_seek(f, info, 0)

    local fat = read_directory(f, info)
    return fat
end

function extract(f, path, offset, length, compressed)
    f:seek("set", offset)
    local data = f:read(length)
    
    if not data then
        error("End of file reached")
    end
    
    if data:len() < length then
        error("Only read " .. tostring(data:len()) .. " of " .. tostring(length) .. " bytes.")
    end

    -- FIXME: Remove if RNC2 decompression gets implemented.
    if compressed then
        path = path .. '.RNC'
    end

    local out, err = io.open(path, 'wb')
    if not out then
        error("Could not open output file: " .. tostring(err))
    end

--    if compressed then
--        tprint({rnc2.decompress(data)})
--    end

    out:write(data)
    out:close()
end

function recurse_extract(f, dir, basepath, path)
    if not basepath then
        basepath = '.'
    end

    if not path then
        path = ""
    end

    for _,e in pairs(dir) do
        if e.name ~= '..' then
            local name = e.name:len() > 0 and e.name or '____NAMELESS____'
            local wpath = path .. name
            print(wpath)

            if b_extract then
                local fpath = basepath .. '/' .. b2f(wpath)

                if e.is_dir then
                    lfs.mkdir(fpath)
                else
                    extract(f, fpath, e.data_offset, e.data_length, e.is_compressed)
                end
            end

            if e.is_dir then
                recurse_extract(f, e.entries, basepath, wpath .. '\\')
            end
        end
    end
end

local f = io.open(arg[1], 'rb')

check_idstring(f)
local info = read_info(f)
local fat = read_fat(f, info)

recurse_extract(f, fat, "output")
