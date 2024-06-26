USE [CCA]
GO
/****** Object:  StoredProcedure [dbo].[procCCA_SSIS_SKServiceCoordState]    Script Date: 5/14/2024 3:20:59 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Jerry Simecek
-- Create date: 20230301
-- Description:	This stored procedure exports data for the UMCM 5.24.10 Service Coordination report. This is for the SK version of the report.
--				This stored procedure will be used by SSIS and the resultant data will be formatted to a .txt file and uploaded to TexConnect.
--				The data is reported by month and this proc takes a start and end date as parameters. 
--				This procedure is getting data from CCA which until run in February 2024 must be combined with historical data from JIVA. 
--				5/12/2023 - Reason Left Blank fix
--				7/20/2023 - HD091680 - Removing duplications
--				11/17/2023 - HD095397 - With the CCA upgrade concept_id 502056 was replaced with 503908. Updated the code accordingly
--					Added first and second run paramters on the job level
--					Moved the Start and End Dates from stored procedures to the package level
--					Per Stephanie Wagers changed the Service Plan logic showing als future plans
--				12/20/2023 - HD096156 - Adjusted code for Service Coordination and Service Plan. Procedure re-named from procMSHCN_UMCM_5_24_10_LTSSCCA to procCCA_SSIS_SKServiceCoordState
--				1/11/2024 - HD096156 - Adjusted logic of the Telephone Contact
-- =============================================
ALTER PROCEDURE [dbo].[procCCA_SSIS_SKServiceCoordState](@reportMonthStart DATE, @reportMonthEnd DATE)

AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @StartDateS As varchar(10), @EndDateS As varchar(10), @SQLStr As varchar(max);
--	DECLARE @reportMonthStart As DATE, @reportMonthEnd As DATE
--	SET @reportMonthStart = DATEFROMPARTS(YEAR(DATEADD(m, -1, GETDATE())), MONTH(DATEADD(m, -1, GETDATE())), 1);
--	SET @reportMonthEnd = DATEADD(d, -1, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1));
--	SET @reportMonthStart = '10/01/2023'
--	SET @reportMonthEnd = '10/30/2023'

	SET @StartDateS = CONVERT(varchar(10), @reportMonthStart);
	SET @EndDateS = CONVERT(varchar(10), @reportMonthEnd);

	DECLARE @SFY varchar(10) = CASE WHEN @reportMonthStart >= CONCAT('9/1/', CAST(YEAR(@reportMonthStart) AS CHAR(4))) THEN YEAR(@reportMonthStart)+1 ELSE YEAR(@reportMonthStart) END
-- 1 START - Getting Demographic data from QNXT - Line 2 - 14
	SET @SQLStr = 'SELECT DISTINCT ''CFC'' As [MCO Name]
		,MONTH(''' + @StartDateS + ''') As [Reporting Month]
		,''' + @SFY + ''' As [State Fiscal Year]
		,''04'' As [Program]
		,''KA'' As [Plan Code]
		,ek.carriermemid As [Medicaid ID/PCN]
		,REPLACE(CONVERT(varchar(10), m.dob, 101), ''/'', '''') As [Member Date of Birth]
		,ent.firstname As [First Name]
		,ent.lastname As [Last Name]
		,CASE WHEN ec.ratecode <> ''S7'' THEN ec.ratecode
			WHEN ec.coveragecodeid = ''CFC-U1'' THEN ''600''
			WHEN ec.coveragecodeid = ''CFC-1-5'' THEN ''601''
			WHEN ec.coveragecodeid = ''CFC-6-14'' THEN ''602''
			WHEN ec.coveragecodeid = ''CFC-15-20'' THEN ''603''
			WHEN ec.coveragecodeid = ''CFC-U1'' THEN ''600''
			WHEN ec.coveragecodeid = ''CFC-1-5'' THEN ''601''
			WHEN ec.coveragecodeid = ''CFC-6-14'' THEN ''602''
			WHEN ec.coveragecodeid = ''CFC-15-20'' THEN ''603''
			WHEN ec.coveragecodeid = ''CFC-MDCP'' THEN ''604''
			WHEN ec.coveragecodeid = ''CFC-MDCP'' THEN ''604''
			WHEN ec.coveragecodeid IN(''TP38'', ''TA06'', ''TP17'') AND FLOOR(DATEDIFF(d, m.dob, GETDATE())/365.25) < 1 THEN ''600''
			WHEN ec.coveragecodeid IN(''TP38'', ''TA06'', ''TP17'') AND FLOOR(DATEDIFF(d, m.dob, GETDATE())/365.25) BETWEEN 1 AND 5 THEN ''601''
			WHEN ec.coveragecodeid IN(''TP38'', ''TA06'', ''TP17'') AND FLOOR(DATEDIFF(d, m.dob, GETDATE())/365.25) BETWEEN 6 AND 14 THEN ''602''
			WHEN ec.coveragecodeid IN(''TP38'', ''TA06'', ''TP17'') AND FLOOR(DATEDIFF(d, m.dob, GETDATE())/365.25) BETWEEN 15 AND 20 THEN ''603''
		ELSE ''XXX'' -- If this happens S7 Crosswolk would have to be updated
		END As [Risk Group]
		,IIF(ek2.enrollid IS NULL, ''01'', ''02'') As [Is this Member new to the MCO in the reporting month?]
		,'''' As [Is this Member newly identified as MSHCN in the reporting month.]
		,ek.memid
	FROM PlanData_rpt.dbo.enrollkeys ek (nolock)
		JOIN PlanData_rpt.dbo.member m (nolock) ON ek.memid = m.memid
		JOIN PlanData_rpt.dbo.entity ent (nolock) ON m.entityid = ent.entid 
		JOIN PlanData_rpt.dbo.enrollcoverage ec (nolock) ON ek.enrollid = ec.enrollid AND ec.effdate < ec.termdate AND ec.termdate >=  ''' + @StartDateS + ''' AND ec.effdate <=  ''' + @EndDateS + '''
		LEFT JOIN PlanData_rpt.dbo.enrollkeys ek2 (nolock) ON ek2.carriermemid = ek.carriermemid AND ek2.effdate < ''' + @StartDateS + ''' AND ek2.termdate >= DATEADD(m, -6, ''' + @StartDateS + ''' ) AND ek2.effdate <> ek2.termdate AND ek2.programid = ''QMXHPQD844'' AND ek2.segtype = ''INT''
	WHERE ek.termdate >= ''' + @StartDateS + ''' 
		AND ek.effdate <= ''' + @EndDateS + '''
		AND ek.programid = ''QMXHPQD844''
		AND ek.segtype = ''INT''
		AND ek.effdate <> ek.termdate
		AND ec.termdate >= ''' + @StartDateS + '''
		AND ec.effdate <= ''' + @EndDateS + '''
		AND ec.effdate <> ec.termdate
	ORDER BY ek.carriermemid;'

	DROP TABLE IF EXISTS ##JSCRQNXTDemo;

	SET @SQLStr = REPLACE(@SQLStr, '''', '''''');

	SET @SQLStr = 'SELECT DISTINCT *
					INTO ##JSCRQNXTDemo
					FROM OPENQUERY([QNXT], ''' + @SQLStr + ''')';

	EXEC(@SQLStr);
	CREATE CLUSTERED INDEX Carriermemid ON ##JSCRQNXTDemo([Medicaid ID/PCN]);
-- 1 END - Getting Demographic data from QNXT Line 2-14

-- 2 START - CCA Data - Line 15 - 17 Did the Member decline service coordination?
	DROP TABLE IF EXISTS #JSCRCCA;

	SELECT DISTINCT jq.*
		,IIF(mhz.Decline = '1', '01', '02') As [Did the Member decline service coordination?]
		,CASE
			WHEN mhz.Decline = '1' AND mhz.Why = '1' THEN 'MDC'
			WHEN mhz.Decline = '1' AND mhz.Why = '2' THEN 'MLT'
			WHEN mhz.Decline = '1' AND mhz.Why = '3' THEN 'MAR'
			WHEN mhz.Decline = '1' AND mhz.Why = '4' THEN 'DEC'
			WHEN mhz.Decline = '1' AND mhz.Why = '5' THEN 'OTH'
		ELSE ''
		END As [If yes, why was service coordination declined?]
		,IIF(mhz.Decline = '1' AND mhz.Why = '5', mhz.Other, '') As [If Other entered, enter a brief explanation]
		,cm.cid
		,op.ID As patient_id
	INTO #JSCRCCA
	FROM ##JSCRQNXTDemo jq
		JOIN [OLTP].[dbo].[member] cm (nolock) ON cm.ssis_external_id = jq.memid COLLATE DATABASE_DEFAULT
		LEFT JOIN (SELECT DISTINCT mhz1.*
						,ROW_NUMBER() OVER (PARTITION BY mhz1.cid ORDER BY mhz1.cid, mhz1.SYS_DATE DESC) RNK		
					FROM (
						SELECT DISTINCT mh.CID
							,mc60.STR_VALUE As Decline
							,mc61.STR_VALUE As Why
							,LEFT(TRIM(REPLACE(REPLACE(REPLACE(mc62.STR_VALUE, CHAR(9), ''), CHAR(13), ''), CHAR(10), '')), 150) As Other
							,mc60.SYS_DATE
						FROM [OLTP].[dbo].[p_member_hra] mh (nolock)
							JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE] mc60 (nolock) ON mc60.CID = mh.CID AND mc60.concept_id = 501860 AND mc60.source_guid = mh.[guid]
							LEFT JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE] mc61 (nolock) ON mc61.CID = mh.CID AND mc61.concept_id = 501861 AND mc61.source_guid = mh.[guid]
							LEFT JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE] mc62 (nolock) ON mc62.CID = mh.CID AND mc62.concept_id = 501862 AND mc62.source_guid = mh.[guid]
						WHERE mh.HRA_ID = 500524 
							AND mh.[status] = 2 
							AND CONVERT(date, mh.SYSTEM_DATE) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND @reportMonthEnd
						
						UNION
						
						SELECT DISTINCT mh1.CID
							,mc60l.STR_VALUE As Decline
							,COALESCE(mc61A.STR_VALUE, mc61l.STR_VALUE) As Why
							,LEFT(TRIM(REPLACE(REPLACE(REPLACE(mc62l.STR_VALUE, CHAR(9), ''), CHAR(13), ''), CHAR(10), '')), 150) As Other
							,mc60l.SYS_DATE
						FROM [OLTP].[dbo].[p_member_hra] mh1 (nolock)
							JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE_LOG] mc60l (nolock) ON mc60l.CID = mh1.CID AND mc60l.concept_id = 501860 AND mc60l.source_guid = mh1.[guid]
							LEFT JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE] mc61A (nolock) ON mc61A.CID = mh1.CID AND mc61A.concept_id = 501861 AND mc61A.source_guid = mh1.[guid]
							LEFT JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE_LOG] mc61l (nolock) ON mc61l.CID = mh1.CID AND mc61l.concept_id = 501861 AND mc61l.source_guid = mh1.[guid]
							LEFT JOIN [OLTP].[dbo].[P_MEMBER_CONCEPT_VALUE] mc62l (nolock) ON mc62l.CID = mh1.CID AND mc62l.concept_id = 501862 AND mc62l.source_guid = mh1.[guid]
						WHERE mh1.HRA_ID = 500524 
							AND mh1.[status] = 2 
							AND CONVERT(date, mh1.SYSTEM_DATE) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND @reportMonthEnd) mhz1) mhz ON mhz.RNK = 1 AND mhz.CID = cm.CID -- String locale 136 type_id = 9 (Status 2 = Completed)
		LEFT JOIN [OLTP].[dbo].[ORG_PATIENT] op (nolock) ON op.CID = cm.CID
		ORDER BY cm.CID

	CREATE CLUSTERED INDEX Index1 ON #JSCRCCA(CID);

	DROP TABLE IF EXISTS ##JSCRQNXTDemo;

-- 2 END - CCA Data - Line 15 - 17 Did the Member decline service coordination?


-- 3 START - Collecting CCA Data - Line 18  and Line 21 - Does member have a service plan -- Member has a service plan if there is ISP form OR 2603 Assessment completed any time between 12 months back and the time we run the report and there are ISP Dates.
--				We are taking latest updated information. It does not have to be tied to the case. The ISP end date >= the start date of the report.

	DROP TABLE IF EXISTS #JSCRL18SvcPl1

	SELECT DISTINCT  cr.CID
		,TRIM(a1.question_value) As ISPStart
		,TRIM(a2.question_value) As ISPEnd
		,oi.create_date
		,CASE WHEN mh.[STATUS] = '2' THEN 'Completed'
			WHEN mh.[STATUS] IN('1', '5', '6') THEN 'InProgress' -- In Progress, Incomplete, Incomplete with errors
		END As [2603Status]
		,mh.SYSTEM_DATE As [2603Date]
		,CASE WHEN mhc.[STATUS] = '2' THEN 'Completed'
			WHEN mhc.[STATUS] IN('1', '5', '6') THEN 'InProgress' -- In Progress, Incomplete, Incomplete with errors
		END As [CoreStatus]
		,mhc.SYSTEM_DATE As [CoreDate]
	INTO #JSCRL18SvcPl1
	FROM #JSCRCCA cr
		JOIN [OLTP].[dbo].[ORG_PATIENT] op (nolock) ON op.CID = cr.CID
		JOIN [OLTP].[dbo].[ORG_NOTEPAD] np (nolock) ON np.PATIENT_ID = op.ID
		JOIN [OLTP].[dbo].[ORG_INFO] oi (nolock) ON oi.id = np.info_id
		JOIN [OLTP].[dbo].[PNAnnotationCommitReport] a1 (nolock) ON a1.progressnote_id = np.info_id AND a1.associatedconcept_id = 502357 -- Current ISP Start Date
		JOIN [OLTP].[dbo].[PNAnnotationCommitReport] a2 (nolock) ON a2.progressnote_id = np.info_id AND a2.associatedconcept_id = 502358 -- Current ISP End Date
		LEFT JOIN [OLTP].[dbo].[p_member_hra] mh (nolock) ON mh.cid = cr.cid AND CONVERT(date, mh.SYSTEM_DATE) >= DATEADD(d, -90, CONVERT(date, TRIM(a1.question_value))) AND mh.HRA_ID = 500545 -- 2603 ISP Assessment
		LEFT JOIN [OLTP].[dbo].[p_member_hra] mhc (nolock) ON mhc.CID = cr.CID AND CONVERT(date, mhc.SYSTEM_DATE) >= DATEADD(d, -90, CONVERT(date, TRIM(a1.question_value))) AND mhc.HRA_ID = 500503 -- LTSS Core Assessment	
	WHERE CONVERT(date, oi.create_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND @reportMonthEnd
		AND CONVERT(date, TRIM(a2.question_value)) >=  @reportMonthStart
	ORDER BY cr.CID, oi.create_date DESC;


	INSERT INTO #JSCRL18SvcPl1
	SELECT DISTINCT  cr.CID
		,TRIM(a1.question_value) As ISPStart
		,TRIM(a2.question_value) As ISPEnd
		,oi.create_date
		,CASE WHEN mh.[STATUS] = '2' THEN 'Completed'
			WHEN mh.[STATUS] IN('1', '5', '6') THEN 'InProgress' -- In Progress, Incomplete, Incomplete with errors
		END As [2603Status]
		,mh.SYSTEM_DATE As [2603Date]
		,CASE WHEN mhc.[STATUS] = '2' THEN 'Completed'
			WHEN mhc.[STATUS] IN('1', '5', '6') THEN 'InProgress' -- In Progress, Incomplete, Incomplete with errors
		END As [CoreStatus]
		,mhc.SYSTEM_DATE As [CoreDate]
	FROM #JSCRCCA cr
		JOIN [OLTP].[dbo].[ORG_PATIENT] op (nolock) ON op.CID = cr.CID
		JOIN [OLTP].[dbo].[ORG_NOTEPAD] np (nolock) ON np.PATIENT_ID = op.ID
		JOIN [OLTP].[dbo].[ORG_INFO] oi (nolock) ON oi.id = np.info_id
		JOIN [OLTP].[dbo].[PNAnnotationCommitReport] a1 (nolock) ON a1.progressnote_id = np.info_id AND a1.associatedconcept_id = 502359 -- New ISP Start Date
		JOIN [OLTP].[dbo].[PNAnnotationCommitReport] a2 (nolock) ON a2.progressnote_id = np.info_id AND a2.associatedconcept_id = 502360 -- -- New ISP End Date
		LEFT JOIN [OLTP].[dbo].[p_member_hra] mh (nolock) ON mh.cid = cr.cid AND CONVERT(date, mh.SYSTEM_DATE) >= DATEADD(d, -90, CONVERT(date, TRIM(a1.question_value))) AND mh.HRA_ID = 500545 -- 2603 ISP Assessment
		LEFT JOIN [OLTP].[dbo].[p_member_hra] mhc (nolock) ON mhc.CID = cr.CID AND CONVERT(date, mhc.SYSTEM_DATE) >= DATEADD(d, -90, CONVERT(date, TRIM(a1.question_value))) AND mhc.HRA_ID = 500503 -- LTSS Core Assessment
	WHERE CONVERT(date, oi.create_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND @reportMonthEnd
		AND CONVERT(date, TRIM(a2.question_value)) >=  @reportMonthStart
	ORDER BY cr.CID, oi.create_date DESC;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL18SvcPl1(CID, create_date DESC);

	DROP TABLE IF EXISTS #JSCRL18SvcPl    

	SELECT DISTINCT d1.CID
		,d1.PlanComplDate
	INTO #JSCRL18SvcPl
	FROM (SELECT d.*
				,ROW_NUMBER() OVER (PARTITION BY d.cid ORDER BY d.cid, d.PlanComplDate DESC) As RNK
			FROM (SELECT CID	
						,IIF(COALESCE([2603Date], '12/31/2078') <= COALESCE([CoreDate], '12/31/2078'), [2603Date], [CoreDate]) As PlanComplDate
					FROM #JSCRL18SvcPl1
					WHERE [2603Status] = 'Completed' OR [CoreStatus] = 'Completed') d) d1
	WHERE d1.RNK = 1
	ORDER BY d1.CID;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL18SvcPl(cid); 
-- 3 END - Collecting CCA Data - Line 18 and Line 21 - Does member have a service plan -- Needs to have ISP2603 form with ISP dates which goes to concepts AND one of the 2603 or Core Assessment completed

-- 4 START - Collecting Concepts needed in this report for updattime between up to 1 year back and end of the report date

	DROP TABLE IF EXISTS #JSCRConcepts;  

	SELECT DISTINCT op.CID
		,a.associatedconcept_id As concept_id
		,a.question_value As STR_VALUE
		,np.id As source_id
		,oi.create_date As update_time
		,np.case_id
		,np.PATIENT_ID
	INTO #JSCRConcepts
	FROM [OLTP].[dbo].[PNAnnotationCommitReport] a
		JOIN [OLTP].[dbo].[ORG_INFO] oi (nolock) ON oi.id = a.progressnote_id
		JOIN [OLTP].[dbo].[ORG_NOTEPAD] np (nolock) ON np.info_id = a.progressnote_id
		JOIN [OLTP].[dbo].[ORG_PATIENT] op (nolock) ON op.id = np.PATIENT_ID
		JOIN #JSCRCCA cr ON cr.cid = op.CID
	WHERE a.associatedconcept_id IN(502050, 502051, 502052, 502053, 502054, 502055, 502056, 502058, 502059, 502057, 503908) -- 502056 replaced with 503908
		AND CONVERT(date, oi.create_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND @reportMonthEnd
		AND a.question_value <> ''
	ORDER BY op.CID, a.associatedconcept_id, np.id, oi.create_date DESC;

	CREATE CLUSTERED INDEX Index1 ON #JSCRConcepts(cid);
-- 4 END - Collecting Concepts needed in this report for updattime between up to 1 year back and end of the report date

-- 5 START - Line 19 If the Member does not have a service plan in place, select the appropriate reason. 
	DROP TABLE IF EXISTS #JSCRL19Reason

	SELECT DISTINCT jc.CID
		,CASE
			WHEN oc2.patient_id IS NOT NULL THEN 'MDC' -- String locale 25 for UM cases 37 - Death or Deceased
			WHEN jc.[Did the Member decline service coordination?] = '01' AND jc.[If yes, why was service coordination declined?] = 'MLT' THEN 'MLT'
			WHEN d1.cid IS NOT NULL THEN 'INP'
			WHEN c6.CallStatus = '1' AND c6.Result = '3' THEN 'MLT' -- Rank 4 Combinations
			WHEN jc.[Did the Member decline service coordination?] = '01' AND jc.[If yes, why was service coordination declined?] = 'DEC' THEN 'DEC'	
			WHEN c6.CallStatus = '1' AND c6.Result IN('1', '4') THEN 'INP' -- Rank 4 Combinations
			WHEN c6.CallStatus = '1' AND c6.Result = '2' THEN 'DEC' -- Rank 4 Combinations

			WHEN c6.CallStatus = '2' AND c6.Result = '3' THEN 'DEC' -- Rank 4 Combinations
			WHEN c6.CallStatus = '2' AND c6.Result  IN('4', '6') THEN 'UTR' -- Rank 4 Combinations
			WHEN c6.CallStatus = '2' AND c6.Result  IN('1', '5') THEN 'INP' -- Rank 4 Combinations
			WHEN c6.CallStatus = '2' AND c6.Result = '5' THEN 'OTH4' -- Rank 4 Combinations
			WHEN oc4.patient_id IS NOT NULL THEN 'INP'
			ELSE 'OTH5'
		END As [Reason]
	INTO #JSCRL19Reason
	FROM #JSCRCCA jc
		LEFT JOIN #JSCRL18SvcPl sp ON sp.cid = jc.cid
		LEFT JOIN (SELECT DISTINCT oc1.patient_id
					FROM [OLTP].[dbo].[ORG_CASE] oc1 (nolock)
					WHERE oc1.[status] = 2 -- Case Closed
						AND oc1.close_reason_type IN(7, 10) -- Dead or Deceased
						AND oc1.tzx_type = 9
						AND oc1.close_date <= @reportMonthEnd
					GROUP BY oc1.patient_id) oc2 ON oc2.patient_id = jc.patient_id
		LEFT JOIN (SELECT DISTINCT d.CID
						FROM #JSCRL18SvcPl1 d
						WHERE (d.[2603Status] = 'InProgress' OR d.[CoreStatus] = 'InProgress')
							AND d.[2603Status] <> 'Completed'
							AND d.[CoreStatus] <> 'Completed') d1 ON d1.CID = jc.CID -- 2603 or Core Assessments In Progress
		LEFT JOIN (SELECT DISTINCT c5.CID
						,c5.CallStatus
						,c5.[Result]
					FROM (SELECT DISTINCT c1.CID
								,c1.STR_VALUE As CallStatus
								,COALESCE(c3.STR_VALUE, c4.STR_VALUE) As Result
								,ROW_NUMBER() OVER (PARTITION BY c1.cid ORDER BY c1.cid, c1.update_time DESC) RNK
							FROM #JSCRConcepts c1
								JOIN #JSCRConcepts c2 ON c2.CID = c1.CID AND c2.concept_id IN(502050, 502051, 502052, 502053) AND c2.source_id = c1.source_id
								LEFT JOIN #JSCRConcepts c3 ON c3.CID = c1.CID AND c3.concept_id = 502058 AND c3.source_id = c1.source_id AND c1.STR_VALUE = '1' -- Successful combination
								LEFT JOIN #JSCRConcepts c4 ON c4.CID = c1.CID AND c4.concept_id = 502059 AND c4.source_id = c1.source_id AND c1.STR_VALUE = '2' -- Unsuccessful combination
							WHERE c1.concept_id = 502057
								AND (c3.cid IS NOT NULL OR c4.CID IS NOT NULL)) c5 
					WHERE c5.RNK = 1) c6 ON c6.CID = jc.CID
		LEFT JOIN (SELECT DISTINCT oc3b.patient_id
						,oc3b.[level]
						,ROW_NUMBER() OVER (PARTITION BY oc3b.patient_id ORDER BY oc3b.patient_id, oc3b.update_date DESC) RNK
					FROM(
						SELECT DISTINCT  oc3a.patient_id
							,oc3a.[level]
							,oc3a.update_date
						FROM [OLTP].[dbo].[ORG_CASE] oc3a (nolock)
						WHERE oc3a.tzx_type = 9
							AND CONVERT(date, oc3a.update_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND  @reportMonthEnd
	
						UNION

						SELECT DISTINCT  oc3a.patient_id
							,oc3a.[level]
							,oc3a.update_date
						FROM [OLTP].[dbo].[ORG_CASE_LOG] oc3a (nolock)
						WHERE oc3a.tzx_type = 9
							AND CONVERT(date, oc3a.update_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND  @reportMonthEnd) oc3b
							) oc4 ON oc4.patient_id = jc.patient_id AND oc4.RNK = 1 AND oc4.[level] = 3
	WHERE sp.CID IS NULL
	ORDER BY jc.CID

	CREATE CLUSTERED INDEX Index1 ON #JSCRL19Reason(cid);
	DROP TABLE IF EXISTS #JSCRL18SvcPl1
-- 5 END - Line 19 If the Member does not have a service plan in place, select the appropriate reason. 

-- 6 START - Line 22 [What is the Member's service coordination or service management level?]
	DROP TABLE IF EXISTS #JSCRL22Level

	SELECT DISTINCT jc.CID
		,COALESCE(oc2.StratLevel, IIF(ot2.patient_id IS NOT NULL, '06', '03')) As [Level]
	INTO #JSCRL22Level
	FROM #JSCRCCA jc
		LEFT JOIN (SELECT DISTINCT oc1a.patient_id
						,CASE
							WHEN oc1a.[level] = 4 THEN '01'
							WHEN oc1a.[level] = 5 THEN '02'
							WHEN oc1a.[level] IN(6, 7) THEN '03'
							WHEN oc1a.[level] = 3 THEN '06'
						END As [StratLevel]
						,ROW_NUMBER() OVER (PARTITION BY oc1a.patient_id ORDER BY oc1a.patient_id, oc1a.update_date DESC) RNK
					FROM(
						SELECT DISTINCT oc1.patient_id
							,oc1.[level]
							,oc1.update_date
						FROM [OLTP].[dbo].[ORG_CASE] oc1 (nolock)
						WHERE oc1.tzx_type = 9
							AND CONVERT(date, oc1.update_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND  @reportMonthEnd
							AND oc1.[level] IS NOT NULL
		
						UNION

						SELECT DISTINCT oc1.patient_id
							,oc1.[level]
							,oc1.update_date
						FROM [OLTP].[dbo].[ORG_CASE_LOG] oc1 (nolock)
						WHERE oc1.tzx_type = 9
							AND CONVERT(date, oc1.update_date) BETWEEN DATEADD(yy, -1, @reportMonthStart) AND  @reportMonthEnd
							AND oc1.[level] IS NOT NULL) oc1a
							) oc2 ON oc2.patient_id = jc.patient_id AND oc2.RNK = 1
		LEFT JOIN (SELECT DISTINCT ot1.patient_id
					FROM [OLTP].[dbo].[ORG_TASK] ot1 (nolock)
						JOIN [OLTP].[dbo].[ORG_INFO] oi1 (nolock) ON oi1.id = ot1.info_id
					WHERE oi1.[subject] IN(
							'LTSS Initial Outreach Attempt 1'
							,'LTSS Initial Outreach Attempt 2'
							,'LTSS Initial Outreach Attempt 3'
							,'LTSS - Perform SAI Assessment in Person'
							,'LTSS - Perform SAI Assessment Telehealth'
							,'LTSS - Perform SAI Assessment Telephone'
							,'Schedule New Member SAI Attempt 1'
							,'Schedule New Member SAI Attempt 2'
							,'Schedule New Member SAI Attempt 3'
							,'Initial Outreach attempt 1'
							,'Initial Outreach attempt 2'
							,'Initial Outreach attempt 3'
							,'Perform SAI Assessment Telephone'
							,'Perform SAI Assessment in Person'
							,'Perform SAI Assessment Telehealth'
							 )
						AND ot1.[status] IN(2, 16)
						AND CONVERT(date, oi1.create_date) BETWEEN @reportMonthStart AND @reportMonthEnd) ot2 ON ot2.patient_id = jc.patient_id
	ORDER BY jc.CID;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL22Level(CID);
-- 6 END - Line 22 [What is the Member's service coordination or service management level?]

-- 7 START - Line 24 [How many successful face-to-face service coordination/service management visits?]
	DROP TABLE IF EXISTS #JSCRL24F2FVisits
	
	SELECT DISTINCT jc.CID
		,CONVERT(varchar(2), COALESCE(c4.F2FCount, 0) + COALESCE(IIF(mh2.AssCount > 1, 1, mh2.AssCount), 0)) As [Visits]
	INTO #JSCRL24F2FVisits
	FROM #JSCRCCA jc
		LEFT JOIN (SELECT DISTINCT c1.CID
						,COUNT(c1.CID) F2FCount
					FROM #JSCRConcepts c1
						JOIN #JSCRConcepts c2 ON c2.CID = c1.CID AND c2.source_id = c1.source_id AND c2.concept_id = 502057 AND c2.STR_VALUE = '1' -- Call sucessful
						JOIN #JSCRConcepts c3 ON c3.CID = c1.CID AND c3.source_id = c1.source_id AND c3.concept_id = 502058 AND c3.STR_VALUE = '4' -- LTSS Performed
					WHERE c1.concept_id = 502055
						AND CONVERT(date, c1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd
					GROUP BY c1.CID) c4 ON c4.CID = jc.CID
		LEFT JOIN (SELECT DISTINCT mh1.cid
						,COUNT(mh1.cid) AssCount
					FROM [OLTP].[dbo].[P_MEMBER_HRA] mh1 (nolock)
					WHERE CONVERT(date, mh1.SYSTEM_DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
						AND mh1.HRA_ID = 500503 
						AND mh1.[STATUS] = '2' -- String locale 136 type_id = 9 (Status 2 = Completed)
					GROUP BY mh1.cid) mh2 ON mh2.cid = jc.cid
	ORDER BY jc.cid;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL24F2FVisits(cid);
-- 7 END - Line 24 [How many successful face-to-face service coordination/service management visits?]

-- 8 START - Line 25 [If no successful face-to-face service coordination/service management visits, why not?]
	DROP TABLE IF EXISTS #JSCRL25F2FReason

	SELECT DISTINCT jc.cid
		,CASE
			WHEN oc2.patient_id IS NOT NULL THEN 'MDC' -- String locale 25 for UM cases 37 - Death or Deceased
			WHEN c5.Result in('1', '2') THEN 'DEC' -- Call successful
			WHEN c5.Result = '3' THEN 'MLT' -- Call successful
			WHEN ca5.Result IN('3', '5') THEN 'DEC' -- Call unsuccessful
			WHEN ca5.Result IN('1', '4', '6') THEN 'UTR' -- Call unsuccessful
			WHEN ca5.Result = '2' THEN 'MAR' -- Call unsuccessful
			WHEN c5.Result = '4' THEN 'OTH1' -- Call successful
			WHEN cb3.CID IS NOT NULL THEN 'OTH'
			ELSE 'F2F'
		END As [Reason]
	INTO #JSCRL25F2FReason
	FROM #JSCRCCA jc
		LEFT JOIN #JSCRL24F2FVisits l24 ON l24.CID = jc.cid AND l24.[Visits] > 0
		LEFT JOIN (SELECT DISTINCT oc1.patient_id -- Line 19
					FROM [OLTP].[dbo].[ORG_CASE] oc1 (nolock)
					WHERE oc1.[status] = 2 -- Case Closed
						AND oc1.close_reason_type IN(7, 10) -- Dead or Deceased
						AND oc1.tzx_type = 9
						AND oc1.close_date <= @reportMonthEnd
					GROUP BY oc1.patient_id) oc2 ON oc2.patient_id = jc.patient_id
		LEFT JOIN (SELECT DISTINCT c4.CID
						,c4.Result
					FROM(SELECT DISTINCT c1.CID -- Call successful
								,c3.STR_VALUE As Result
								,ROW_NUMBER() OVER (PARTITION BY c1.cid ORDER BY c1.cid, c1.update_time DESC) RNK
							FROM #JSCRConcepts c1
								JOIN #JSCRConcepts c2 ON c2.CID = c1.CID AND c2.source_id = c1.source_id AND c2.concept_id = 502057 AND c2.STR_VALUE = '1'
								JOIN #JSCRConcepts c3 ON c3.CID = c1.CID AND c3.source_id = c1.source_id AND c3.concept_id = 502058
							WHERE c1.concept_id IN(502050, 502051, 502052, 502053, 502054, 502055)
								AND CONVERT(date, c1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd) c4 
					WHERE c4.RNK = 1) c5 ON c5.CID = jc.CID
		LEFT JOIN (SELECT DISTINCT ca4.CID
						,ca4.Result
					FROM (SELECT DISTINCT ca1.CID -- Call unsuccessful
								,ca3.STR_VALUE As Result
								,ROW_NUMBER() OVER (PARTITION BY ca1.cid ORDER BY ca1.cid, ca1.update_time DESC) RNK
							FROM #JSCRConcepts ca1
								JOIN #JSCRConcepts ca2 ON ca2.CID = ca1.CID AND ca2.source_id = ca1.source_id AND ca2.concept_id = 502057 AND ca2.STR_VALUE = '2'
								JOIN #JSCRConcepts ca3 ON ca3.CID = ca1.CID AND ca3.source_id = ca1.source_id AND ca3.concept_id = 502059
							WHERE ca1.concept_id IN(502050, 502051, 502052, 502053, 502054, 502055)
								AND CONVERT(date, ca1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd) ca4
							WHERE ca4.RNK = 1) ca5 ON ca5.CID = jc.CID
	LEFT JOIN (SELECT DISTINCT cb1.CID -- OTH
					FROM #JSCRConcepts cb1
						JOIN #JSCRConcepts cb2 ON cb2.CID = cb1.CID AND cb2.source_id = cb1.source_id AND cb2.concept_id = 502057
					WHERE cb1.concept_id IN(502050, 502051, 502052, 502053, 502054, 502055)
						AND CONVERT(date, cb1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd) cb3 ON cb3.CID = jc.CID
	WHERE l24.CID IS NULL
	ORDER BY jc.CID;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL25F2FReason(cid);
-- 8 END - Line 25 [If no successful face-to-face service coordination/service management visits, why not?]

-- 9 START - Line 27 [How many successful telephonic service coordination/service management visits?]
	DROP TABLE IF EXISTS #JSCRL27Tel

	SELECT DISTINCT jc.cid
				,CONVERT(varchar(2), COALESCE(mh2.AssCount, 0) + COALESCE(c4.CallCount, 0)) As [Visits]
	INTO #JSCRL27Tel
	FROM #JSCRCCA jc
		LEFT JOIN (SELECT DISTINCT mh1.cid
						,COUNT(mh1.cid) AssCount
					FROM [OLTP].[dbo].[P_MEMBER_HRA] mh1 (nolock)
					WHERE mh1.HRA_ID IN(500537, 500520, 500522, 500498, 500499, 500500, 500501, 500504)
						AND mh1.[STATUS] = '2' -- String locale 136 type_id = 9 (Status 2 = Completed)
						AND CONVERT(date, mh1.create_date) BETWEEN @reportMonthStart AND @reportMonthEnd
					GROUP BY mh1.cid) mh2 ON mh2.cid = jc.cid
		LEFT JOIN (SELECT DISTINCT c1.CID -- Call successful
						,COUNT(c1.CID) As CallCount
					FROM #JSCRConcepts c1
						JOIN #JSCRConcepts c2 ON c2.CID = c1.CID AND c2.source_id = c1.source_id AND c2.concept_id = 502057 AND c2.STR_VALUE = '1' -- Call successful
						JOIN #JSCRConcepts c3 ON c3.CID = c1.CID AND c3.source_id = c1.source_id AND c3.concept_id = 502058 AND c3.STR_VALUE = '4' -- LTSS performed
					WHERE CONVERT(date, c1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd
						AND c1.concept_id IN(502056, 503908)
					GROUP BY c1.CID) c4 ON c4.CID = jc.CID
	ORDER BY jc.cid;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL27Tel(cid);
-- 9 END - Line 27 [How many successful telephonic service coordination/service management visits?]

-- 10 START - Line 28 [If no successful telephonic service coordination/service management visits made, why not?]
	DROP TABLE IF EXISTS #JSCRL28TReason

	SELECT DISTINCT jc.cid
		,CASE
			WHEN oc2.patient_id IS NOT NULL THEN 'MDC' -- String locale 25 for UM cases 37 - Death or Deceased
			WHEN c4.Result in('1', '2') THEN 'DEC' -- Call successful
			WHEN c4.Result = '3' THEN 'MLT' -- Call successful
			WHEN ca4.Result IN('3', '5') THEN 'DEC' -- Call unsuccessful
			WHEN ca4.Result IN('1', '4', '6') THEN 'UTR' -- Call unsuccessful
			WHEN ca4.Result = '2' THEN 'MAR' -- Call unsuccessful
			WHEN cb3.CID IS NOT NULL THEN 'OTH'
			ELSE 'TEL'
		END As [Reason]
	INTO #JSCRL28TReason
	FROM #JSCRCCA jc
		LEFT JOIN #JSCRL27Tel l27 ON l27.CID = jc.cid AND l27.[Visits] > 0
		LEFT JOIN (SELECT DISTINCT oc1.patient_id
					FROM [OLTP].[dbo].[ORG_CASE] oc1 (nolock)
					WHERE oc1.[status] = 2 -- Case Closed
						AND oc1.close_reason_type IN(7, 10) -- Dead or Deceased
						AND oc1.tzx_type = 9
						AND oc1.close_date <= @reportMonthEnd
					GROUP BY oc1.patient_id) oc2 ON oc2.patient_id = jc.patient_id
		LEFT JOIN (SELECT DISTINCT  c1.CID -- Call successful
						,c3.STR_VALUE As Result
						,ROW_NUMBER() OVER(PARTITION BY c1.cid ORDER BY c1.cid, c1.update_time DESC) RNK
					FROM #JSCRConcepts c1
						JOIN #JSCRConcepts c2 ON c2.CID = c1.CID AND c2.source_id = c1.source_id AND c2.concept_id = 502057 AND c2.STR_VALUE = '1'
						JOIN #JSCRConcepts c3 ON c3.CID = c1.CID AND c3.source_id = c1.source_id AND c3.concept_id = 502058
					WHERE CONVERT(date, c1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd
						AND c1.concept_id IN(502056, 503908)) c4 ON c4.CID = jc.CID AND c4.RNK = 1
		LEFT JOIN (SELECT DISTINCT  ca1.CID -- Call unsuccessful
						,ca3.STR_VALUE As Result
						,ROW_NUMBER() OVER (PARTITION BY ca1.cid ORDER BY ca1.cid, ca1.update_time DESC) RNK
					FROM #JSCRConcepts ca1
						JOIN #JSCRConcepts ca2 ON ca2.CID = ca1.CID AND ca2.source_id = ca1.source_id AND ca2.concept_id = 502057 AND ca2.STR_VALUE = '2'
						JOIN #JSCRConcepts ca3 ON ca3.CID = ca1.CID AND ca3.source_id = ca1.source_id AND ca3.concept_id = 502059
					WHERE CONVERT(date, ca1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd
						AND ca1.concept_id IN(502056, 503908)) ca4 ON ca4.CID = jc.CID AND ca4.RNK = 1


		LEFT JOIN (SELECT DISTINCT cb1.CID -- OTH
					FROM #JSCRConcepts cb1
						JOIN #JSCRConcepts cb2 ON cb2.CID = cb1.CID AND cb2.source_id = cb1.source_id AND cb2.concept_id = 502057
					WHERE CONVERT(date, cb1.update_time) BETWEEN @reportMonthStart AND @reportMonthEnd
						AND cb1.concept_id IN(502056, 503908)) cb3 ON cb3.CID = jc.CID
	WHERE l27.CID IS NULL
	ORDER BY jc.CID;

	CREATE CLUSTERED INDEX Index1 ON #JSCRL28TReason(cid);
-- 10 END - Line 28 [If no successful telephonic service coordination/service management visits made, why not?]

-- 11 START - Final sumary
	SELECT DISTINCT ROW_NUMBER() OVER(ORDER BY jcf.[Medicaid ID/PCN]) As [Sequence] -- Line2
		,jcf.*
	FROM
		(SELECT DISTINCT jc.[MCO Name] -- Line 3
			,jc.[Reporting Month] -- Line 4
			,jc.[State Fiscal Year] -- Line 5
			,jc.[Program] -- Line 6
			,jc.[Plan Code] -- Line 7
			,jc.[Medicaid ID/PCN] -- Line 8
			,jc.[Member Date of Birth] -- Line 9
			,jc.[First Name] -- Line 10
			,jc.[Last Name] -- Line 11
			,jc.[Risk Group] -- Line 12
			,jc.[Is this Member new to the MCO in the reporting month?] -- Line 13
			,jc.[Is this Member newly identified as MSHCN in the reporting month.] -- Line 14
			,IIF(IIF(l18.cid IS NULL, '02', '01') = '01', '02', jc.[Did the Member decline service coordination?]) As [Did the Member decline service coordination?] -- Line 15
			-- Line 16
			,IIF(IIF(IIF(l18.cid IS NULL, '02', '01') = '01', '02', jc.[Did the Member decline service coordination?]) = '02', '', jc.[If yes, why was service coordination declined?]) As [If yes, why was service coordination declined?]
			-- Line 17
			,IIF(l18.cid IS NOT NULL, '', jc.[If Other entered, enter a brief explanation]) As [If Other entered, enter a brief explanation]
			,IIF(l18.cid IS NULL, '02', '01') As [Does the Member have a service plan in place?] -- Line 18
			,LEFT(COALESCE(l19.Reason, ''), 3) As [If the Member does not have a service plan in place, select the appropriate reason.] -- Line 19
			-- Line 20
			,CASE
				WHEN l19.Reason = 'OTH4' THEN 'Member at Risk to themselves'
				WHEN l19.Reason = 'OTH5' THEN 'Unable to determine based on documentation crosswalk'
				ELSE ''
			END  As [If "Other" selected, provide a brief explanation.]
			,COALESCE(REPLACE(CONVERT(varchar(10), l18.PlanComplDate, 101), '/', ''), '') As [Date the service plan was developed or last updated?] -- Line 21
			,l22.[Level] As [What is the Member's service coordination or service management level?] -- Line 22
			-- Line 23
			,IIF(l25.Reason = 'F2F' AND l28.Reason = 'TEL', '02', '01') As [Was at least one service coordination contact attempt made?]
			-- Line 24
			,IIF(l25.Reason = 'F2F' AND l28.Reason = 'TEL', '', l24.Visits)  As [How many successful face-to-face service coordination/service management visits?]
			-- Line 25
			,CASE 
				WHEN l25.Reason = 'F2F' AND l28.Reason = 'TEL' THEN ''
				WHEN l25.Reason = 'OTH1' THEN 'OTH'
			ELSE COALESCE(l25.Reason, '')
			END As [If no successful face-to-face service coordination/service management visits, why not?]
			-- Line 26
			,CASE
				WHEN l25.Reason = 'F2F' AND l28.Reason = 'TEL' THEN ''
				WHEN l25.Reason = 'OTH' THEN 'Not F2F but activity outcome selected by the SC does not allow for categorization into the DEC, UTR, MAR or MLT category'
				WHEN l25.Reason = 'OTH1' THEN 'Member Scheduled F2F for later date and/or Service Plan is in development'
				ELSE ''
			END As [If OTH entered for Row 25, enter a brief explanation.]
			-- Line 27
			,IIF(l25.Reason = 'F2F' AND l28.Reason = 'TEL', '', l27.[Visits]) As [How many successful telephonic service coordination/service management visits?]
			-- Line 28
			,IIF(l25.Reason = 'F2F' AND l28.Reason = 'TEL', '', COALESCE(l28.[Reason], '')) As [If no successful telephonic service coordination/service management visits made, why not?]
			-- Line 29
			,CASE 
				WHEN l25.Reason = 'F2F' AND l28.Reason = 'TEL' THEN ''
				WHEN l28.Reason = 'OTH' THEN 'Not TEL but activity outcome selected by the SC does not allow for categorization into the DEC, UTR, MAR or MLT category'
				ELSE ''
			END As [If Other, provide brief description.]
		FROM #JSCRCCA jc
			LEFT JOIN #JSCRL18SvcPl l18 ON l18.cid = jc.CID
			LEFT JOIN #JSCRL19Reason l19 ON l19.cid = jc.CID
			LEFT JOIN #JSCRL22Level l22 ON l22.CID = jc.CID
			LEFT JOIN #JSCRL24F2FVisits l24 ON l24.CID = jc.CID
			LEFT JOIN #JSCRL25F2FReason l25 ON l25.CID = jc.CID
			LEFT JOIN #JSCRL27Tel l27 ON l27.CID = jc.CID
			LEFT JOIN #JSCRL28TReason l28 ON l28.CID = jc.CID) jcf
	ORDER BY jcf.[Medicaid ID/PCN];
-- 11 END - Final sumary


-- 12 START - Cleaning
	DROP TABLE IF EXISTS #JSCRCCA
	DROP TABLE IF EXISTS #JSCRL18SvcPl
	DROP TABLE IF EXISTS #JSCRL19Reason
	DROP TABLE IF EXISTS #JSCRL22Level
	DROP TABLE IF EXISTS #JSCRL24F2FVisits
	DROP TABLE IF EXISTS #JSCRL25F2FReason 
	DROP TABLE IF EXISTS #JSCRL27Tel
	DROP TABLE IF EXISTS #JSCRL28TReason
-- 12 END - Cleaning

END;