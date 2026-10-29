-- Display names for record types and field mnemonics.  Cosmetic only: the
-- buffer parser ignores them.

local M = {}

M.records = {
  [1] = "Transaction Information",
  [2] = "User-defined Descriptive Text",
  [3] = "Low-resolution Grayscale Fingerprint",
  [4] = "High-resolution Grayscale Fingerprint",
  [5] = "Low-resolution Binary Fingerprint",
  [6] = "High-resolution Binary Fingerprint",
  [7] = "User-defined Image",
  [8] = "Signature Image",
  [9] = "Minutiae Data",
  [10] = "Facial & SMT Image",
  [11] = "Voice",
  [12] = "Forensic Dental",
  [13] = "Variable-resolution Latent Image",
  [14] = "Variable-resolution Fingerprint",
  [15] = "Variable-resolution Palmprint",
  [16] = "User-defined Variable-resolution Image",
  [17] = "Iris Image",
  [18] = "DNA",
  [19] = "Plantar",
  [20] = "Source Representation",
  [21] = "Associated Context",
  [22] = "Non-photographic Imagery",
  [98] = "Information Assurance",
  [99] = "CBEFF Biometric Data",
}

local common = { [1] = "LEN", [2] = "IDC" }

-- Fields shared by the variable-resolution image records (13-17).
local image = {
  [3] = "IMP", [4] = "SRC", [5] = "FCD", [6] = "HLL", [7] = "VLL", [8] = "SLC",
  [9] = "THPS", [10] = "TVPS", [11] = "CGA", [12] = "BPX", [13] = "FGP",
  [999] = "DATA",
}

local fields = {
  [1] = {
    [1] = "LEN", [2] = "VER", [3] = "CNT", [4] = "TOT", [5] = "DAT", [6] = "PRY",
    [7] = "DAI", [8] = "ORI", [9] = "TCN", [10] = "TCR", [11] = "NSR", [12] = "NTR",
    [13] = "DOM", [14] = "GMT", [15] = "DCS",
  },
  -- EBTS Type-2 element names.
  [2] = {
    [5] = "RET", [9] = "OCA", [14] = "UCN", [15] = "SID", [16] = "SOC", [17] = "MNU",
    [18] = "NAM", [19] = "AKA", [20] = "POB", [21] = "CTZ", [22] = "DOB", [24] = "SEX",
    [25] = "RAC", [26] = "SMT", [27] = "HGT", [29] = "WGT", [31] = "EYE", [32] = "HAI",
    [35] = "PPA", [36] = "PHT", [37] = "RFP", [38] = "DPR", [39] = "EAD", [40] = "OCP",
    [41] = "RES", [45] = "DOA", [73] = "CRI",
  },
  [9] = { [3] = "IMP", [4] = "FMT" },
  [10] = {
    [3] = "IMT", [4] = "SRC", [5] = "PHD", [6] = "HLL", [7] = "VLL", [8] = "SLC",
    [9] = "THPS", [10] = "TVPS", [11] = "CGA", [12] = "CSP", [20] = "POS",
    [999] = "DATA",
  },
  [13] = image,
  [14] = image,
  [15] = setmetatable({ [13] = "PLP" }, { __index = image }),
  [16] = image,
  [17] = { [999] = "DATA" },
  [99] = { [999] = "BDB" },
}

function M.field(record_type, num)
  local t = fields[record_type]
  return (t and t[num]) or common[num] or (num == 999 and "DATA" or nil)
end

return M
