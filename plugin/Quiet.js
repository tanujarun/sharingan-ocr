// A shared "hold still" switch: while anything holds it, items registered with add() get quiet = true and can pause
// per-frame work so the overlay has the render thread to itself. `.pragma library` gives importers one shared copy.
.pragma library

var holders = []
var members = []

function publish() {
  var on = holders.length > 0
  for (var i = 0; i < members.length; i++) {
    try { members[i].quiet = on } catch (e) { }
  }
}
function add(item) { if (members.indexOf(item) === -1) members.push(item) }
function remove(item) { var i = members.indexOf(item); if (i !== -1) members.splice(i, 1) }
function hold(key) { if (holders.indexOf(key) === -1) { holders.push(key); publish() } }
function release(key) { var i = holders.indexOf(key); if (i !== -1) { holders.splice(i, 1); publish() } }
