module.exports = async function iemAdminHandler(request, response) {
  const { default: handler } = await import("../Website/api/iem-admin.js");
  return handler(request, response);
};
