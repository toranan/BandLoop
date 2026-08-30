module.exports = async function feedbackHandler(request, response) {
  const { default: handler } = await import("../Website/api/feedback.js");
  return handler(request, response);
};
