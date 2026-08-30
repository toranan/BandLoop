module.exports = async function feedbackAdminHandler(request, response) {
  const { default: handler } = await import("../Website/api/feedback-admin.js");
  return handler(request, response);
};
