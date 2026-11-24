const notFound = () => new Response("Not found", { status: 404 });

export { notFound as GET, notFound as POST };
