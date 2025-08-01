local action_set = require("telescope.actions.set")
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local strings = require("plenary.strings")
local utils = require("telescope.utils")
local conf = require("telescope.config").values
local git_worktree = require("git-worktree")

local force_next_deletion = false

local get_worktree_path = function()
  local selection = action_state.get_selected_entry()
  return selection.path
end

local switch_worktree = function(prompt_bufnr)
  local worktree_path = get_worktree_path()
  actions.close(prompt_bufnr)
  if worktree_path ~= nil then
    git_worktree.switch_worktree(worktree_path)
  end
end

local toggle_forced_deletion = function()
  -- redraw otherwise the message is not displayed when in insert mode
  if force_next_deletion then
    print("The next deletion will not be forced")
    vim.fn.execute("redraw")
  else
    print("The next deletion will be forced")
    vim.fn.execute("redraw")
    force_next_deletion = true
  end
end

local delete_success_handler = function()
  force_next_deletion = false
end

local delete_failure_handler = function()
  print("Deletion failed, use <C-f> to force the next deletion")
end

local ask_to_confirm_deletion = function(forcing)
  if forcing then
    return vim.fn.input("Force deletion of worktree? [y/n]: ")
  end

  return vim.fn.input("Delete worktree? [y/n]: ")
end

local confirm_deletion = function(forcing)
  if not git_worktree._config.confirm_telescope_deletions then
    return true
  end

  local confirmed = ask_to_confirm_deletion(forcing)

  if string.sub(string.lower(confirmed), 0, 1) == "y" then
    return true
  end

  print("Didn't delete worktree")
  return false
end

local delete_worktree = function(prompt_bufnr)
  if not confirm_deletion() then
    return
  end

  local worktree_path = get_worktree_path()
  actions.close(prompt_bufnr)

  -- If removing current worktree, switch to root first
  local current_worktree_path = git_worktree.get_current_worktree_path()
  if current_worktree_path == worktree_path then
    git_worktree.switch_worktree(git_worktree.get_root())
  end

  if worktree_path ~= nil then
    git_worktree.delete_worktree(worktree_path, force_next_deletion, {
      on_failure = delete_failure_handler,
      on_success = delete_success_handler,
    })
  end
end

local create_input_prompt = function(cb)
  local subtree = vim.fn.input("Path to subtree > ")
  cb(subtree)
end

local create_worktree = function(opts)
  opts = opts or {}
  opts.attach_mappings = function()
    actions.select_default:replace(function(prompt_bufnr, _)
      local selected_entry = action_state.get_selected_entry()
      local current_line = action_state.get_current_line()

      actions.close(prompt_bufnr)

      local branch = selected_entry ~= nil and selected_entry.value
        or current_line

      if branch == nil then
        return
      end

      create_input_prompt(function(name)
        if name == "" then
          name = branch
        end
        git_worktree.create_worktree(name, branch)
      end)
    end)

    -- do we need to replace other default maps?

    return true
  end
  require("telescope.builtin").git_branches(opts)
end

local open_picker = function(opts, execute, mappings)
  opts = opts or {}
  local output = utils.get_os_command_output({ "git", "worktree", "list" })
  local results = {}
  local widths = {
    path = 0,
    sha = 0,
    branch = 0,
  }

  local parse_line = function(line)
    local fields = vim.split(string.gsub(line, "%s+", " "), " ")
    local entry = {
      path = fields[1],
      sha = fields[2],
      branch = fields[3],
    }

    if entry.sha ~= "(bare)" then
      local index = #results + 1
      for key, val in pairs(widths) do
        if key == "path" then
          -- Some users have found that transform_path raises an error because telescope.state#get_status
          -- outputs an empty table. When that happens, we need to use the default value.
          -- This seems to happen in distros such as AstroNvim and NvChad
          --
          -- Reference: https://github.com/ThePrimeagen/git-worktree.nvim/issues/97
          local transformed_ok, new_path =
            pcall(utils.transform_path, opts, entry[key])

          if transformed_ok then
            local path_len = strings.strdisplaywidth(new_path or "")
            widths[key] = math.max(val, path_len)
          else
            widths[key] =
              math.max(val, strings.strdisplaywidth(entry[key] or ""))
          end
        else
          widths[key] = math.max(val, strings.strdisplaywidth(entry[key] or ""))
        end
      end

      table.insert(results, index, entry)
    end
  end

  -- Make sure output is not nil
  assert(output ~= nil)
  for _, line in ipairs(output) do
    parse_line(line)
  end

  if #results == 0 then
    return
  end

  local displayer = require("telescope.pickers.entry_display").create({
    separator = " ",
    items = {
      { width = widths.branch },
      { width = widths.path },
      { width = widths.sha },
    },
  })

  local make_display = function(entry)
    return displayer({
      { entry.branch, "TelescopeResultsIdentifier" },
      { entry.path, utils.transform_path(opts, entry.path)[2] },
      { entry.sha },
    })
  end

  pickers
    .new(opts or {}, {
      prompt_title = "Git Worktrees",
      finder = finders.new_table({
        results = results,
        entry_maker = function(entry)
          entry.value = entry.branch
          entry.ordinal = entry.branch
          entry.display = make_display
          return entry
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(_, map)
        action_set.select:replace(execute)

        for _, tab in ipairs(mappings) do
          map(tab.modes, tab.map, tab.fun, { desc = tab.desc })
        end

        return true
      end,
    })
    :find()
end

local telescope_git_worktree = function(opts)
  local mappings = {}
  table.insert(mappings, {
    modes = { "i", "n" },
    map = "<C-d>",
    fun = delete_worktree,
    desc = "Delete worktree",
  })
  table.insert(mappings, {
    modes = { "i", "n" },
    map = "<C-f>",
    fun = toggle_forced_deletion,
    desc = "Force delete worktree",
  })

  open_picker(opts, switch_worktree, mappings)
end

local delete_git_worktree = function(opts)
  local mappings = {}
  table.insert(mappings, {
    modes = { "i", "n" },
    map = "<C-f>",
    fun = toggle_forced_deletion,
    desc = "Force delete worktree",
  })

  open_picker(opts, delete_worktree, mappings)
end

return require("telescope").register_extension({
  exports = {
    git_worktree = telescope_git_worktree,
    git_worktrees = telescope_git_worktree,
    create_git_worktree = create_worktree,
    delete_git_worktree = delete_git_worktree,
  },
})
