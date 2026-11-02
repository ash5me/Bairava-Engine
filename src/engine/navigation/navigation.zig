//! Navigation for AI: the walkable cells of a tile map, A* routes over them, and a follower that walks a box along a
//! route through the map's collision. This is engine code, so it names no game type. The game uses it through
//! `engine.navigation`. See docs/navigation.md for the rules and the limits.

const grid = @import("grid.zig");
const pathfind = @import("pathfind.zig");
const follow = @import("follow.zig");
const agent = @import("agent.zig");

/// A cell of the map, counted from the top-left corner.
pub const Cell = grid.Cell;
/// Which cells of a tile map a unit can stand on, and the sight lines between points.
pub const Grid = grid.Grid;
/// The cell that holds a point in pixels, and the center of a cell.
pub const cellOf = grid.cellOf;
pub const cellCenter = grid.cellCenter;

/// Finds cheapest routes between cells. It keeps its arrays between searches.
pub const Pathfinder = pathfind.Pathfinder;
pub const FindError = pathfind.FindError;

/// Walks a box along a route, one waypoint at a time, through the map's collision.
pub const Follower = follow.Follower;
/// The most cells one route may hold.
pub const max_path = follow.max_path;

/// Owns an A* pathfinder and a follower for an entity navigating to one goal.
pub const Agent = agent.Agent;
