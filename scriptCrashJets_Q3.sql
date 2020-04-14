/*
*Procedimento para obter horário e lotação de determinado voo
*/
CREATE PROCEDURE [dbo].[usp_Lotacao](@VooId int)
AS
	BEGIN
		DECLARE @Capacidade INT;
		DECLARE @ReservasFeitas INT;
		SET @Capacidade=0;
		SET @ReservasFeitas=0;

		SELECT @Capacidade=a.[av_lot]
			from aviao a inner join voo v on v.av_id=a.av_id
			where v.[voo_id]=@VooId;

		SELECT @ReservasFeitas=(count(r.res_id))
				from reserva r inner join voo v on r.voo_id=v.voo_id
				where (r.voo_id=@VooId);

		IF(@ReservasFeitas<@Capacidade)
			begin
				SELECT [voo_id],[voo_data],[voo_part],[voo_dest],(@Capacidade-@ReservasFeitas) as Vagas 
					from voo where voo_id=@VooId;
			end
		ELSE 
			begin
				SELECT [voo_id],[voo_data],[voo_part],[voo_dest],'Lotação Esgotada' as Vagas 
					from voo where voo_id=@VooId;
			end
	END
GO