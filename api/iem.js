module.exports = async function iemHandler(request, response) {
  const { default: handler } = await import("../Website/api/iem.js");
  return handler(request, response);
};
