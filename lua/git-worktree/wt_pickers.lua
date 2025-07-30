local git_worktree = require("git-worktree")
local snack_picker = require("snacks.picker")

local Pickers = {}

-- Strip string of extra spaces
---@param s string
---@return string
local do_strip = function(s)
  -- Strip beginning
  s = string.gsub(s, "^%s+", "")

  -- Strip end
  s = string.gsub(s, "%s+$", "")

  -- Reduce all others
  s = string.gsub(s, "%s+", " ")

  return s
end

-- Split string s with pattern, strip spaces if strip is true
-- (default, false)
---@param s string
---@param pattern string
---@param strip boolean?
---@return string[]
local split_string = function(s, pattern, strip)
  if strip == nil then
    strip = false
  end

  local result = {}
  while string.len(s) > 1 do
    -- Get next occurrence of "pat"
    local index0, index1 = string.find(s, pattern)
    if not index0 then
      -- Save the rest and exit
      if strip then
        s = do_strip(s)
      end

      result[#result + 1] = s
      break
    end

    -- Only add if we have something to add
    if index0 > 1 then
      local save = string.sub(s, 1, index0 - 1)
      if strip then
        save = do_strip(save)
      end
      result[#result + 1] = save

      assert(index1)
      s = string.sub(s, index1)
    else
      s = string.sub(s, 2)
    end
  end

  return result
end

-- Picker to get branches
---@param only_branches boolean?
---@param only_worktrees boolean?
local get_branches = function(only_branches, only_worktrees)
  if only_branches == nil then
    only_branches = false
  end
  if only_worktrees == nil then
    only_worktrees = false
  end

  assert(only_worktrees or only_branches)

  -- Retrieve all branches
  local args = "git branch -vvl"
  local command_out = vim.api.nvim_cmd({
    cmd = "!",
    args = { args },
    mods = { silent = true },
  }, { output = true })

  -- Trim the command_out from anything before "\r\n\n"
  command_out =
    string.sub(command_out, string.find(command_out, "\r\n\n") + 3)

  -- Split by "\n"
  local worktree_list = split_string(command_out, "\n", true)

  local items = {}
  for _, wt in ipairs(worktree_list) do
    local worktree_table = {}

    -- Save message
    worktree_table.text = wt

    -- Split the string
    local split_wt = split_string(wt, '%s+')

    -- Save the values
    local index = 1
    if split_wt[1] == "*" then
      worktree_table.current = true
      worktree_table.is_worktree = true
      index = index + 1
    elseif split_wt[1] == "+" then
      worktree_table.current = false
      worktree_table.is_worktree = true
      index = index + 1

      if not only_worktrees then
        goto continue
      end
    else
      worktree_table.current = false
      worktree_table.is_worktree = false

      if not only_branches then
        goto continue
      end
    end

    ---@param s string[]
    ---@param joiner string
    ---@param start number?
    ---@return string
    local join_string = function (s, joiner, start)
      local new_string = s[start]
      for i = start + 1, #s, 1 do
        new_string = new_string .. joiner .. s[i]
      end

      return new_string
    end

    worktree_table.branch = split_wt[index]
    worktree_table.commit = split_wt[index + 1]
    local join_wt = join_string(split_wt, " ", index + 2)
    worktree_table.msg = join_wt

    -- Find path
      local open = string.find(join_wt, '(', 1, true)
    if open then
      local close = string.find(join_wt, ')', 1, true)
      worktree_table.path = string.sub(join_wt, open + 1, close - 1)
    end

    -- Only save it if we want to
    items[#items + 1] = worktree_table

    ::continue::
  end

  return items
end

---@param call_on_path function
---@param force_delete boolean?
local pick_worktree_path = function(call_on_path, title, force_delete)

  if title == nil then
    title = "Search"
  end

  snack_picker.pick({
    force_delete = force_delete,
    items = get_branches(false, true),
    format = "git_branch",
    preview = "git_log",
    title = title,
    confirm = function(picker, item)
      picker:close()
      if not item.current then
        call_on_path(item.path, picker.force_delete)
      end
    end,

    -- Map to toggle force deletion
    win = {
      input = {
        keys = {
          ["<c-f>"] = { "git_force_deletion", mode = { "n", "i" } },
        },
      },
    },
    actions = {
      git_force_deletion = function(picker)
        picker.force_delete = not picker.force_delete
        if picker.force_delete then
          print("Force delete on")
        else
          print("Force delete off")
        end
      end
    },
  })
end

---@param call_on_confirm function
---@param title string?
local pick_or_find_branch = function (call_on_confirm, title)

  if title == nil then
    title = "Search"
  end

  snack_picker.pick({
    items = get_branches(true, false),
    format = "git_branch",
    preview = "git_log",
    title = title,
    confirm = function(picker, item)
      picker:close()

      -- If new value was introduced, get that
      local branchname
      if item == nil then
        branchname = picker.finder.filter.pattern
      else
        branchname = item.branch
        if item.current then
          return nil
        end
      end

      -- Get a path from the user
      local prompt = 'Path for branch "' .. branchname .. '": '
      vim.ui.input({prompt = prompt}, function(input)
        call_on_confirm(input, branchname)
      end)
    end
  })
end

Pickers.switch_worktree_picker = function()
  pick_worktree_path(git_worktree.switch_worktree, "Switch to")
end

Pickers.delete_worktree_picker = function()
  local delete_failure_handler = function()
    print("Deletion failed, use <C-f> to force the next deletion")
  end

  pick_worktree_path(function(path, force_delete)
    -- If removing current worktree, switch to root first
    local current_worktree_path = git_worktree.get_current_worktree_path()
    if current_worktree_path == path then
      git_worktree.switch_worktree(git_worktree.get_root())
    end

    git_worktree.delete_worktree(path, force_delete, {
      on_failure = delete_failure_handler,
      -- on_success = delete_success_handler,
    })
  end, "Delete", false)
end

Pickers.create_worktree_picker = function()
  pick_or_find_branch(git_worktree.create_worktree, "Choose or create branch")
end

return Pickers
