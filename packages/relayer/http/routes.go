package http

func (srv *Server) configureRoutes() {
	srv.echo.GET("/healthz", srv.Health)

	srv.echo.GET("/events", srv.GetEventsByAddress)
}
