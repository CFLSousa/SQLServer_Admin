/*
*Transação de reserva de um voo com validação de lotação do aviao
*/
CREATE PROCEDURE [dbo].[usp_EfetuarReserva](@VooId int,@PassId int,@RefId int,@PrecoExtras int)
AS
	BEGIN
		DECLARE @Capacidade INT;
		DECLARE @ReservasFeitas INT;
		DECLARE @CartaoMilhas INT;
		DECLARE @DistMilhas INT;
		SET @Capacidade=0;
		SET @ReservasFeitas=0;
		SET @CartaoMilhas=0;
		SET @DistMilhas=0;
		
		SELECT @Capacidade=a.[av_lot]
			from aviao a inner join voo v on v.av_id=a.av_id
			where v.[voo_id]=@VooId;

		SELECT @ReservasFeitas=(count(r.res_id))
				from reserva r inner join voo v on r.voo_id=v.voo_id
				where (r.voo_id=@VooId);
				
		IF(@ReservasFeitas<@Capacidade)
			begin
				BEGIN TRANSACTION;
					INSERT [dbo].[reserva]([bilhete_emitido],[res_data],[voo_id],[pass_id],[ref_id],[preco_extras]) 
						VALUES
							('S',getdate(),@VooId,@PassId,@RefId,@PrecoExtras);		
					SELECT @CartaoMilhas=[cartao_milhas] from passageiro where pass_id=@PassId;
					SELECT @DistMilhas=[dist_milhas] from voo where voo_id=@VooId;
					UPDATE passageiro
						set cartao_milhas=(@CartaoMilhas+@DistMilhas)
						where pass_id=@PassId;
				COMMIT;
			end
		ELSE
			begin
				print isnull(N'Overbooking.','(null)');
			end
	END
GO