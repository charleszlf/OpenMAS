%% 2D GEOMETRIC COLLISION AVOIDANCE AGENT (agent_2D_VO.m) %%%%%%%%%%%%%%%%%


% Author: James A. Douthwaite

classdef agent_2D_VO < agent_2D & agent_VO
    %% ////////////////////// MAIN CLASS METHODS //////////////////////////
    methods 
        % CONSTRUCTOR METHOD
        function [obj] = agent_2D_VO(varargin)
            % Construct the agent object and initialise with the following
            % specific parameters.

            % CALL THE SUPERCLASS CONSTRUCTOR
            obj@agent_2D(varargin); 
            
            % INPUT HANDLING (Clean up nested loops)
            [varargin] = obj.inputHandler(varargin);     
            
            % Omit superclass field
            obj.feasabliltyMatrix = [];  % Omit parent field
            
            % //////////////////// SENSOR PARAMETERS //////////////////////
            [obj.SENSORS] = obj.GetDefaultSensorParameters();       % Default sensing
            %[obj.SENSORS] = obj.GetCustomSensorParameters();       % Experimental sensing
            % /////////////////////////////////////////////////////////////
            
            % CHECK FOR USER OVERRIDES
            % - It is assumed that overrides to the properties are provided
            %   via the varargin structure.
            obj = obj.configurationParser(obj,varargin);
        end
        % SETUP - x = [x y psi dx dy dpsi]
        function [obj] = setup(obj,localXYZVelocity,localXYZrotations)
            [obj] = obj.initialise_2DVelocities(localXYZVelocity,localXYZrotations);
        end
        % MAIN
        function [obj] = main(obj,ENV,varargin)
            % INPUTS:
            % obj      - The agent object
            % TIME     - The current time structure
            % varargin - Cell array of inputs
            % OUTPUTS:
            % obj      - The updated object
            
            % GET THE TIMESTEP
            dt = ENV.dt;
            
            % PLOT AGENT FIGURE
            visualiseProblem = 0;
            visualiseAgent = 1;
            if obj.objectID == visualiseAgent && visualiseProblem == 1
                overHandle = figure(100 + obj.objectID);
                hold on; grid on;
                axis equal;
                xlabel('x_{m}'); ylabel('y_{m}'); zlabel('z_{m}');
            end 
            
            % //////////// CHECK FOR NEW INFORMATION UPDATE ///////////////
            % UPDATE THE AGENT WITH THE NEW ENVIRONMENTAL INFORMATION
            [obj] = obj.GetAgentUpdate(ENV,varargin{1}); 

            % /////////////////// WAYPOINT TRACKING ///////////////////////
            desiredHeadingVector = obj.GetTargetHeading();                    % Design the current desired trajectory from the waypoint.  
            desiredVelocity = desiredHeadingVector*obj.nominalSpeed;
            
            % ////////////////// OBSTACLE AVOIDANCE ///////////////////////
            % Modify the desired velocity with the augmented avoidance velocity.
            algorithm_start = tic; algorithm_indicator = 0;  avoidanceEnabled = 1;  
            if avoidanceEnabled
                algorithm_indicator = 1;
                % GET THE UPDATED DESIRED VELOCITY
                [desiredHeadingVector,desiredSpeed] = obj.GetAvoidanceCorrection(dt,desiredVelocity,visualiseProblem);
                desiredVelocity = desiredHeadingVector*desiredSpeed;
            end
            algorithm_dt = toc(algorithm_start);                           % Stop timing the algorithm
                   
            % APPLY SPEED CONSTRAINT
            desiredSpeed = norm(desiredVelocity);
            if desiredSpeed > obj.maxSpeed
                desiredHeadingVector = desiredVelocity/norm(desiredVelocity);
                desiredVelocity = desiredHeadingVector*obj.maxSpeed;
            end  
            
            % ///////////////////// CONTROLLER ////////////////////////////
            [obj] = obj.controller(dt,desiredVelocity);
            
            % ////////////// RECORD THE AGENT-SIDE DATA ///////////////////
            obj = obj.writeAgentData(ENV,algorithm_indicator,algorithm_dt);
            obj.DATA.inputNames = {'$v_x$ (m/s)','$v_y$ (m/s)','$\dot{\psi}$ (rad/s)'};
            obj.DATA.inputs(1:length(obj.DATA.inputNames),ENV.currentStep) = obj.localState(4:6);         % Record the control inputs
        end
    end
    %% /////////////////////// AUXILLARY METHODS //////////////////////////
    
    % //////////////////// VELOCITY OBSTACLE METHODS //////////////////////
    methods 
        % CALCULATE THE NECESSARY 2D AVOIDANCE VELOCITY
        function [headingVector,speed] = GetAvoidanceCorrection(obj,dt,desiredVelocity,figureLogical)
            % This function calculates the 2D avoidance velocity command
            % and returns it to be achieved by the controller.
            
            % Input sanity check
            assert(numel(desiredVelocity) == 2,'Desired velocity must be 2D');
            
            % AGENT KNOWLEDGE (2D)
            [p_i,v_i,r_i] = obj.GetAgentMeasurements();
            
            % GET OBSTACLE DATA
            obstacleIDs  = [obj.MEMORY([obj.MEMORY.type] == OMAS_objectType.obstacle).objectID];
            agentIDs     = [obj.MEMORY([obj.MEMORY.type] == OMAS_objectType.agent).objectID];
            avoidanceIDs = [agentIDs,obstacleIDs];
            
            % MOVE THROUGH THE PRIORITISED OBSTACLE SET
            VO = [];
            for item = 1:numel(avoidanceIDs)
                % Get object data from memory structure
                p_j = obj.GetLastMeasurementByObjectID(avoidanceIDs(item),'position');
                v_j = obj.GetLastMeasurementByObjectID(avoidanceIDs(item),'velocity');
                r_j = obj.GetLastMeasurementByObjectID(avoidanceIDs(item),'radius');
                
                % NEIGHBOUR CONDITIONS
                neighbourConditionA = item < obj.maxNeighbours;            % Maximum number of neighbours
                neighbourConditionB = norm(p_j) < obj.neighbourDist;       % [CONFIRMED] 
                neighbourConditionC = ~any(isnan(v_j));                    % Wait for a valid velocity reading
                if ~neighbourConditionB || ~neighbourConditionC
                    continue
                end
       
                % OBSTACLE KNOWLEDGE
                p_j = p_j + p_i; 
                v_j = v_j + v_i;                                           % Convert relative parameters to absolute
                tau_j = 0;
                
                % DEFINE THE VELOCITY OBSTACLE PROPERTIES
                VO_i = obj.define2DVelocityObstacle(p_i,v_i,r_i,p_j,v_j,r_j,tau_j,figureLogical);
                VO_i.objectID = avoidanceIDs(item);                        % Add a unique identifier
                VO = [VO,VO_i];
            end

            % THE CLEAR PATH STRATEGY
            [avoidanceVelocity] = obj.strategy_clearPath(v_i,desiredVelocity,VO,figureLogical);              
            
            % SPECIAL CASE- VELOCITY MAGNITUDE IS ZERO
            speed = norm(avoidanceVelocity);
            headingVector = avoidanceVelocity/speed;
            if isnan(headingVector)
                headingVector = [1;0];  % Retain previous heading
            end

            % PLOT THE VECTOR CONSTRUCT
            if figureLogical && obj.objectID == figureLogical
                % PLOT THE LEADING TANGENT VECTOR
                OMAS_axisTools.drawTriad([p_i;0],eye(3));
                
                % CURRENT VELOCITY
                q = quiver(gca,p_i(1),p_i(2),v_a(1),v_a(2),'m');
                q.AutoScaleFactor = 1;
                % DESIRED VELOCITY
                q = quiver(gca,p_i(1),p_i(2),desiredVelocity(1),desiredVelocity(2),'g');
                q.AutoScaleFactor = 1;   
                % AVOIDANCE VELOCITY
                q = quiver(gca,p_i(1),p_i(2),avoidanceVelocity(1),avoidanceVelocity(2),'b');
                q.AutoScaleFactor = 1; 
            end
        end          
        % ASSEMBLE THE 2D VELOCITY OBSTACLE (VO)
        function [VO] = define2DVelocityObstacle(obj,p_a,v_a,r_a,p_b,v_b,r_b,tau,plotOn)
            % This function assembles the standard velocity obstacle
            % in 2D. 
            
            % MAP THE 2D INPUTS TO 3D 
            p_a = [p_a;0]; v_a = [v_a;0];
            p_b = [p_b;0]; v_b = [v_b;0];
            % CALL THE 3D VO GENERATION FUNCTION
            VO = obj.define3DVelocityObstacle(p_a,v_a,r_a,p_b,v_b,r_b,tau,plotOn);
            % ALTER THE VO PARAMETERS 
            VO.apex = VO.apex(1:2,1);
            VO.axisUnit = VO.axisUnit(1:2,1);
            VO.leadingEdgeUnit = VO.leadingEdgeUnit(1:2,1);
            VO.trailingEdgeUnit = VO.trailingEdgeUnit(1:2,1);
            VO.truncationCircleCenter = VO.truncationCircleCenter(1:2,1);
        end 
        % CLEAR PATH STRATEGY
        function [optimalVelocity] = strategy_clearPath(obj,v_a,desiredVelocity,VOset,plotOn)
            % This function computes the optimal avoidance velocity using
            % the 'clear path' method of calculating the closest point to
            % the desired velocity on the surface of the VO set.
            
            % INPUT HANDLING
            if numel(VOset) == 0
               optimalVelocity = desiredVelocity;
               return
            end
            
            p_a = obj.localState(1:2,1);    % For plotting
            
            % ////////////// BUILD THE PROJECTION SET /////////////////////
            % We build a list of projection points, of closest proximity to
            % the desired velocity. There will be two projection points per
            % VO. 
            projectionPoints = zeros(2,2*numel(VOset));
            isOnRayPoints    = ones(1,2*numel(VOset));
            a = 0;  
            for VOnumA = 1:numel(VOset)
                % THE FIRST VERTEX EDGE
                [projections(:,1),isOnRay(1)] = obj.pointProjectionToRay(desiredVelocity,VOset(VOnumA).apex,VOset(VOnumA).leadingEdgeUnit);
                % THE SECOND VERTEX EDGE
                [projections(:,2),isOnRay(2)] = obj.pointProjectionToRay(desiredVelocity,VOset(VOnumA).apex,VOset(VOnumA).trailingEdgeUnit);

                % COLLECT THE PROJECTIONS POINTS
                % The projections of 'v_a' on both the leadingEdgeUnit, trailingEdgeUnit
                isOnRayPoints((1 + a*VOnumA):(2 + a*VOnumA)) = isOnRay;          % CONCATINATE THE IS ON RAY 
                projectionPoints(:,(1 + a*VOnumA):(2 + a*VOnumA)) = projections; % STORE ALL PROJECTION POINTS
                a = a + 1;
            end

            % /////////// BUILD THE INTERSECTION POINT SET ////////////////
            % GET THE INTERSECTIONS BETWEEN TWO SETS OF LEADING & TRAILING
            % EDGES
            VOsum = numel(VOset);
            intersectionFlags  = ones(1,4*VOsum*(VOsum-1)/2);
            intersectionPoints = zeros(2,4*VOsum*(VOsum-1)/2);
            a = 0;
            for VOnum_i = 1:numel(VOset)
                for VOnum_j = 1:numel(VOset)
                    if VOnum_i == VOnum_j 
                       continue % Skip self comparison (also omits singular VO condition) 
                    end
                    pIntersect = zeros(2,4);
                    % LEADING - LEADING
                    [pIntersect(:,1),validIntersect(1)] = obj.twoRayIntersection2D(...
                        VOset(VOnum_i).apex,...
                        VOset(VOnum_i).leadingEdgeUnit,...
                        VOset(VOnum_j).apex,...
                        VOset(VOnum_j).leadingEdgeUnit);
                    % LEADING - TRAILING
                    [pIntersect(:,2),validIntersect(2)] = obj.twoRayIntersection2D(...
                        VOset(VOnum_i).apex,...
                        VOset(VOnum_i).leadingEdgeUnit,...
                        VOset(VOnum_j).apex,...
                        VOset(VOnum_j).trailingEdgeUnit);                    
                    % TRAILING - LEADING
                    [pIntersect(:,3),validIntersect(3)] = obj.twoRayIntersection2D(...
                        VOset(VOnum_i).apex,...
                        VOset(VOnum_i).trailingEdgeUnit,...
                        VOset(VOnum_j).apex,...
                        VOset(VOnum_j).leadingEdgeUnit);
                    % TRAILING - TRAILING
                    [pIntersect(:,4),validIntersect(4)] = obj.twoRayIntersection2D(...
                        VOset(VOnum_i).apex,...
                        VOset(VOnum_i).trailingEdgeUnit,...
                        VOset(VOnum_j).apex,...
                        VOset(VOnum_j).trailingEdgeUnit);        
                    
                    % There are four intersections per pair of VO. 

                    % RETAIN THE POINTS & FLAGS
                    intersectionFlags(:,(1 + 4*a):4*(1 + a)) = validIntersect; % If the corresponding point was a valid intersection
                    intersectionPoints(:,(1 + 4*a):4*(1 + a)) = pIntersect;    % The intersection point array
                    a = a + 1;
                end
            end
            
            % ASSSESS THE COLLECTIVE POINT SET AGAINSTS THE VO SET
            % All valid projections and intersection must be compared
            % against thw VO set.
            
            % OMIT NON-VALID PROJECTIONS
            validProjectionPoints = projectionPoints(:,(isOnRayPoints == 1));    % Get only the projections where the points are on rays            
            % REMOVE ANY NON-INTERSECTIONS
            validIntersectionPoints = intersectionPoints(:,(intersectionFlags == 1)); % Are valid intersections

            % CONSIDER THE CURRENT VELOCITY IN THE CANDIDATE SET
            collectivePoints = [desiredVelocity,validProjectionPoints,validIntersectionPoints]; % <<< TO BE CONFIRMED
            collectivePoints = unique(collectivePoints','rows');           % Remove repeat candidates
            collectivePoints = collectivePoints';
            
            % ///////// CHECK EACH POINT AGAINST THE VO SET ///////////////
            VOflagVector = zeros(1,size(collectivePoints,2));
            for candidate = 1:size(collectivePoints,2)
                for VOnum_i = 1:numel(VOset)
                    % DETERMINE WHETHER THE POINT BELONGS TO ANY VO
                    if VOflagVector(candidate) || obj.isInsideVO(collectivePoints(:,candidate),VOset(VOnum_i))
                    	VOflagVector(candidate) = 1;
                    end
                end
            end
            
            % REMOVE THE VO-INVALIDATED CANDIDATE POINTS
            candidatesOutsideVO = collectivePoints(:,VOflagVector ~= 1);
            
            % ///// CHOOSE OPTIMAL VELOCITY FROM THE CANDIDATE POINTS /////
            optimalMetricDistance = inf;  % Metric of optimality
            compareVelocity = desiredVelocity;
            
            % DEFAULT VELOCITY
            optimalVelocity = zeros(2,1);
            
            if size(candidatesOutsideVO,2) > 0 
                % ASSESS VELOCITIES AGAINST THE DESIRED VELOCITY
                for k = 1:size(candidatesOutsideVO,2)
                    dis = norm(candidatesOutsideVO(:,k) - compareVelocity);
                    if dis < optimalMetricDistance 
                        optimalVelocity = candidatesOutsideVO(:,k);
                        optimalMetricDistance = dis;
                    end
                end
            elseif isempty(candidatesOutsideVO)
                % IN THE EVENT THERE ARE NO VALID VELOCITIES
                warning('There is no feasible velocity!');
                optimalVelocity = zeros(2,1);                
            end
            
            % //////////////////  PLOT THE SCENE //////////////////////////
            if obj.objectID == 1 && plotOn
                hold on; grid on;
                for proj_i = 1:size(projectionPoints,2)
                    plotProj = p_a + projectionPoints(:,proj_i);
                    scatter(gca,plotProj(1),plotProj(2),'r');
                end
                
                for inter_j = 1:size(intersectionPoints,2)
                    plotProj = p_a + intersectionPoints(:,inter_j);
                    scatter(gca,plotProj(1),plotProj(2),'b');
                end
                
                % FILL IN VALID POINTS
                for validPoint = 1:size(candidatesOutsideVO,2)
                   scatter(gca,p_a(1) + candidatesOutsideVO(1,validPoint),p_a(2) + candidatesOutsideVO(2,validPoint),'b','filled'); 
                end
                
                % OUR VELOCITY
                q = quiver(gca,p_a(1),p_a(2),v_a(1),v_a(2),'r');
                q.AutoScaleFactor = 1;
                
                % DESIRED VELOCITY
                q = quiver(gca,p_a(1),p_a(2),desiredVelocity(1),desiredVelocity(2),'b');
                q.AutoScaleFactor = 1;
                scatter(gca,p_a(1) + desiredVelocity(1),p_a(2) + desiredVelocity(2),'b');
                
                % THE OPTIMAL VELOCITY
                q = quiver(gca,p_a(1),p_a(2),optimalVelocity(1),optimalVelocity(2),'m');
                q.AutoScaleFactor = 1;
                scatter(gca,p_a(1) + optimalVelocity(1),p_a(2) + optimalVelocity(2),'m');
                
                for VOnum_i = 1:numel(VOset)
                    leadingEdgeVector = VOset(VOnum_i).axisLength*VOset(VOnum_i).leadingEdgeUnit;
                    trailingEdgeVector = VOset(VOnum_i).axisLength*VOset(VOnum_i).trailingEdgeUnit;
                    apexPosition = p_a + VOset(VOnum_i).apex;
                    q = quiver(gca,apexPosition(1),apexPosition(2),leadingEdgeVector(1),leadingEdgeVector(2),'r');
                    q.AutoScaleFactor = 1;
                    q = quiver(gca,apexPosition(1),apexPosition(2),trailingEdgeVector(1),trailingEdgeVector(2),'b');
                    q.AutoScaleFactor = 1;
                end
                close all;
            end
        end
    end   
    % //////////////////////////// UTILITIES //////////////////////////////
    methods (Static) 
        % TWO LINE INTERSECTIONS (FROM agent_VO)
        function [p_inter,isSuccessful] = twoRayIntersection2D(P1,dP1,P2,dP2)
            % Find the intersection point between two 2D vectors. This
            % function isnt' interested if vertices are infront or behind
            % of the starting point.
            % INPUTS:
            % - P1,P2   - The ray defining points.
            % - dP1,dP2 - The ray unit directions.
            % OUTPUTS:
            % - p_inter - The 2D intersection point.
            
            assert(numel(P1) == 2,'Input must be 2D');
            assert(numel(P2) == 2,'Input must be 2D');
            
            % SOME SUFFICIENTLY SMALL VALUE FOR INTERSECTION
            isSuccessful = logical(false);   % Default to no intersection
            p_inter = NaN(2,1);              % Default to no intersection
            
            % THE 2D DETERMININANT
            div = dP1(2)*dP2(1) - dP1(1)*dP2(2);
            if div == 0
                disp('Lines are parallel');
                return % Lines are parallel
            end
            
            % THE SCALAR PROJECTIONS
            mua = (dP2(1)*(P2(2) - P1(2)) + dP2(2)*(P1(1) - P2(1))) / div;
            mub = (dP1(1)*(P2(2) - P1(2)) + dP1(2)*(P1(1) - P2(1))) / div;
            
            % POINTS MUST BE THE RESULT OF A POSITIVE INCREMENT OF THE VECTOR GRADIENT
            % (i.e, in the correct direction)
            if mua < 0 || mub < 0   % Intersections only occur in the direction of the vector
                return              % Lines do not intersect
            end
            
            % THE INTERSECTION POINT
            p_inter = P1 + mua*dP1;
            isSuccessful = logical(true);
        end
        % GET THE POINT PROJECTION ON RAY
        function [projectedPoint,isOnTheRay] = pointProjectionToRay(p,p0,v0)
            % INPUTS:
            % p  - Is the point to be projected.
            % p0,v0 - The line defining points
            % OUTPUTS:
            %
            projectedPoint = v0*v0'/(v0'*v0)*(p - p0) + p0;
            
            if v0'*(projectedPoint - p0)>0 % if on the ray
                isOnTheRay = logical(true);
            else
                isOnTheRay = logical(false);
            end
        end
        % CHECK THE AGENT VELOCITY IS INSIDE THE VO
        function [flag] = isInsideVO(point,VO)
            % determine if the point p is inside the given VO
            % angle<halfOpenAngle; here numericalTolerance is an error tolarance
            
            flag = 0;
            VOtolerance = 1E-8;

            candidateVector = point - VO.apex;
            VOprojection   = norm(candidateVector)*cos(VO.openAngle/2);
            candProjection = VO.axisUnit'*candidateVector;
            projDiff = (candProjection - VOprojection);
            if projDiff > VOtolerance   
                flag = 1;
            end
        end
    end
end
% AGENT STATE VECTOR [x;y;psi;xdot;ydot;psidot]